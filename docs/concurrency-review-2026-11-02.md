# Tern sync concurrency review, 2026-11-02

Reviewed mail sync, calendar sync, IMAP monitoring, and their app lifecycle integration with `swift-concurrency-pro`. The findings below are implemented. Confidence is high in each reported interleaving and fix.

The installed compiler is Swift 6.2.4. Core specifies Swift tools 6.2; the app uses Swift 6 language mode. Neither enables default MainActor isolation or `NonisolatedNonsendingByDefault`. The latter remains opt-in in Swift 6.2, so the review used the actual target settings. See [Swift's feature documentation](https://docs.swift.org/latest/documentation/diagnostics/nonisolated-nonsending-by-default/).

## GmailRequestBudget.swift

[Default sleeper at line 88](/Users/developer/GitHub/REA_Mime/Packages/Core/Sources/GmailAPI/GmailRequestBudget.swift:88): **Async closure code generation on Swift 6.2.4.** The full core run aborted in `scheduleWake` during `swift_task_dealloc`, with `freed pointer was not the last allocation`. Its async sleeper was a public default argument. This matches [Swift issue #92017](https://github.com/swiftlang/swift/issues/92017), including the compiler version: default-argument closure copies in different modules can disagree on task-frame size. The default closure now lives in the library initializer body, avoiding those competing copies. Existing calls remain source compatible.

```swift
// Before
sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
// Initializer body: self.sleep = sleep

// After
sleep: (@Sendable (Duration) async throws -> Void)? = nil
// Initializer body:
self.sleep = sleep ?? { try await Task.sleep(for: $0) }
```

## SyncEngine.swift

[Shutdown at line 273](/Users/developer/GitHub/REA_Mime/Packages/Core/Sources/SyncEngine/SyncEngine.swift:273): **Actor reentrancy and task ownership.** The first `stop()` cleared task handles before awaiting them. A second caller could therefore return while background work was still running. Retaining handles until the joins finish makes concurrent shutdown callers wait for the same work.

```swift
// Before
pollTask = nil
for task in background { await task.value }

// After
for task in background { await task.value }
pollTask = nil
```

[Shared sync at line 419](/Users/developer/GitHub/REA_Mime/Packages/Core/Sources/SyncEngine/SyncEngine.swift:419): **Cooperative cancellation.** A cancelled caller could start a new pass or report success after awaiting an existing pass. Cancellation is now checked before admission and after the shared task completes. Cancelling one caller leaves the shared pass available to other callers.

```swift
// Before
return try await task.value

// After (also check before starting or joining)
try Task.checkCancellation()
let changed = try await task.value
try Task.checkCancellation()
return changed
```

[Label freshness at line 489](/Users/developer/GitHub/REA_Mime/Packages/Core/Sources/SyncEngine/SyncEngine.swift:489) and [line 647](/Users/developer/GitHub/REA_Mime/Packages/Core/Sources/SyncEngine/SyncEngine.swift:647): **Revalidate shared state after suspension.** A label change could invalidate the cache while a full or incremental sync was fetching an older snapshot. That sync then marked labels fresh again, suppressing the required full listing. A generation now records invalidation independently of the timestamp.

```swift
// Before
labelsRefreshedAt = passStart

// After (capture labelGeneration before the awaited work)
if labelRefreshGeneration == labelGeneration { labelsRefreshedAt = passStart }
```

## ActionQueue.swift and LabelQueue.swift

[ActionQueue.swift:593](/Users/developer/GitHub/REA_Mime/Packages/Core/Sources/SyncEngine/ActionQueue.swift:593), [LabelQueue.swift:384](/Users/developer/GitHub/REA_Mime/Packages/Core/Sources/SyncEngine/LabelQueue.swift:384), and [LabelQueue.swift:426](/Users/developer/GitHub/REA_Mime/Packages/Core/Sources/SyncEngine/LabelQueue.swift:426): **Consistent shared-state invalidation.** Label edits, creation, and deletion now invalidate the generation as well as the timestamp. These are the call sites for the label race above.

```swift
// Before
labelsRefreshedAt = nil
// After
invalidateLabels()
```

## SnoozeKeeper.swift

[Shutdown at line 38](/Users/developer/GitHub/REA_Mime/Packages/Core/Sources/SyncEngine/SnoozeKeeper.swift:38): **Drain owned work before returning.** Shutdown waited for automatic checks but could return while an explicit snooze mutation was still writing durable account configuration. An operation-gate barrier now waits for mutations already admitted.

```swift
// Before
await checking?.value
// After
await checking?.value
await operations.perform {}
```

[Check ownership at line 118](/Users/developer/GitHub/REA_Mime/Packages/Core/Sources/SyncEngine/SnoozeKeeper.swift:118): **Clear a shared task within its owner.** A new check could join a task that had finished but whose original caller had not yet cleared its handle. Its requested rerun would be lost. Cleanup now happens inside the task before it completes.

```swift
// Before
let task = Task { await runChecks() }
await task.value
checking = nil
scheduleNextCheck()

// After
let task = Task {
    await runChecks()
    checking = nil
    scheduleNextCheck()
}
```

## CalendarStore.swift

[Commit validation at line 117](/Users/developer/GitHub/REA_Mime/Packages/Core/Sources/MailStore/CalendarStore.swift:117): **Atomically validate the complete expected state.** Empty incremental responses advance the sync token without changing the event revision. Comparing only generation and revision allowed a late response to roll the cursor backward. Commits now compare the token in the same database transaction.

```swift
// Before
guard state.generation == expected.generation, state.revision == expected.revision else { /* reject */ }
// After
guard state.generation == expected.generation, state.revision == expected.revision,
      state.syncToken == expected.syncToken else { /* reject */ }
```

[Conditional reset at line 100](/Users/developer/GitHub/REA_Mime/Packages/Core/Sources/MailStore/CalendarStore.swift:100): **Stale failures must not erase newer state.** A delayed expired-token response could reset events and a cursor already committed by another sync. Reset now optionally requires the request's expected generation, revision, and token, checked atomically. Existing intentional unconditional resets retain their behavior.

## CalendarSyncEngine.swift

[Calendar listing at line 63](/Users/developer/GitHub/REA_Mime/Packages/Core/Sources/SyncEngine/CalendarSyncEngine.swift:63): **Serialize shared snapshot replacement.** Overlapping list requests could commit out of order. Callers now share one engine-owned task; each validates cancellation and access after joining, and shutdown cancels and drains it.

```swift
// Before: each caller independently fetches and replaces the list.
// After: create or join calendarListRequest, then validate the result.
let snapshot = try await request.value
try checkpoint(snapshot.epoch)
return snapshot.calendars
```

[Expired-token recovery at line 125](/Users/developer/GitHub/REA_Mime/Packages/Core/Sources/SyncEngine/CalendarSyncEngine.swift:125) uses the store's conditional reset:

```swift
// Before
try await store.resetRemoteCalendar(accountID: accountID, calendarID: calendarID)
// After
try await store.resetRemoteCalendar(accountID: accountID, calendarID: calendarID, expected: state)
```

## InboxMonitor.swift and IdleTimers.swift

[Input handling at line 199](/Users/developer/GitHub/REA_Mime/Packages/Core/Sources/IMAPIdle/InboxMonitor.swift:199) and [timer identity validation](/Users/developer/GitHub/REA_Mime/Packages/Core/Sources/IMAPIdle/IdleTimers.swift:35): **Cancellation cannot retract buffered stream events.** A timeout already queued behind a server reply could survive cancellation and close a healthy connection after a replacement timer was armed. Each expiration now carries its registration identity; cancelled, replaced, and duplicate events are rejected. Input processing also checks task cancellation after stream suspension.

```swift
// Before
actions = session.timerFired(timer, at: .now)
// After
guard timers.consume(expiration) else { continue }
actions = session.timerFired(expiration.timer, at: .now)
```

## CalendarModel.swift

[Startup at line 100](/Users/developer/GitHub/REA_Mime/App/Calendar/CalendarModel.swift:100), [shutdown at line 168](/Users/developer/GitHub/REA_Mime/App/Calendar/CalendarModel.swift:168), and [refresh at line 229](/Users/developer/GitHub/REA_Mime/App/Calendar/CalendarModel.swift:229): **Lifecycle admission, reentrancy, and cancellation.** Delayed startup could install a store or monitor after shutdown. A queued refresh could recreate engines after shutdown. Startup now validates its generation after suspension, shutdown retains teardown work, and replacement startup waits for that work before reopening refresh admission. Refresh checks its revision after account, preference, and occurrence reads and ignores stale failures.

```swift
// Before
store = try await openStore()
// After (abbreviated store-opening path)
let openedStore = try await openStore()
guard generation == startGeneration, !isStopped else { return }
try Task.checkCancellation()
store = openedStore

// Before: refresh accepted calls after stop.
// After
guard !isStopped, !Task.isCancelled else { return }
```

## AppModel.swift

[Watcher reconciliation at line 371](/Users/developer/GitHub/REA_Mime/App/AppModel.swift:371): **Revalidate loop decisions after suspension.** An old reconciliation could stop one watcher, suspend, then remove a newly installed watcher for a later account using its stale eligibility list. Each removal now checks that the reconciliation is still current.

```swift
// Before
await inboxWatchers.removeValue(forKey: id)?.stop()
// After
guard !inboxUpdatesAreStopped, revision == inboxReconciliationRevision else { return }
await inboxWatchers.removeValue(forKey: id)?.stop()
```

## AccountMailbox.swift

[Event handling at line 206](/Users/developer/GitHub/REA_Mime/App/Mailbox/AccountMailbox.swift:206): **Reject callbacks after lifecycle invalidation.** Shutdown released the process activity, then awaited snooze shutdown before cancelling event consumption. A queued sync-start event could reacquire that activity and leave it held. Stopped or cancelled consumers now ignore events.

```swift
// Before
switch event { /* update status and process activity */ }
// After
guard !isStopped, !Task.isCancelled else { return }
switch event { /* update status and process activity */ }
```

## Verification

- `swift test --package-path Packages/Core --filter 'SyncEngineTests|IMAPIdleTests|CalendarStoreTests'`: 255 tests in 35 suites passed. The later full run also passed every regression added by this review.
- App tests for `CalendarModelTests`, `InboxWatcherTests`, `AccountMailboxTests`, `SyncActivityGuardTests`, and `CacheResetLifecycleTests`: 26 tests in five suites passed against the final calendar lifecycle changes. [App test log](/tmp/tern-concurrency-app-tests-final.log).
- A final Debug app build passed after rebuilding `GmailRequestBudget.swift` with the default-sleeper workaround. [Build log](/tmp/tern-concurrency-app-build-verified.log).
- The final full core run passed all 601 tests in 103 suites. On follow-up, `GoogleSessionTests.transportCancellationOnlyBecomesTaskCancellationWhenTheTaskWasCancelled` was extended to cover reads and sends with and without Swift-task cancellation. It expects four attempts and seven seconds of simulated backoff only for an active read; sends and cancelled Swift tasks make one attempt without backoff. Production retry behavior is unchanged, and the previous expectation mismatch is resolved. [Full core log](/tmp/tern-concurrency-core-tests-all-passed.log).
- The full core run no longer crashed after the default-sleeper workaround. The earlier allocator crash is recorded in [the crash report](/Users/developer/Library/Logs/DiagnosticReports/swiftpm-testing-helper-2026-11-02-012154.ips).
- `git diff --check` passed. Independent review covered the changed task ownership, cancellation, and database commit checks.

Validation used controlled service responses and local stores; a live Gmail, Calendar, or IMAP round trip was not performed. Existing and concurrently produced workspace changes were preserved.

## Priorities addressed

1. Prevent stale calendar responses from erasing current data or regressing cursors, make shutdown wait for durable writes, and avoid the observed Swift 6.2.4 quota-timer crash.
2. Prevent stopped calendar work and outdated account reconciliation from recreating or removing active runtimes.
3. Preserve label invalidation, reject stale IMAP timer events, and honor cancellation without cancelling shared work for other callers.
