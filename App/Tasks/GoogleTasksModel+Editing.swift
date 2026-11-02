import Foundation
import GmailAPI

extension GoogleTasksModel {
    /// Email additions always use the email's account, even if another account
    /// is visible. A list selection is captured before the first suspension.
    @discardableResult
    func add(_ request: TaskCreationRequest, retryAfterReview: Bool = false) async -> Bool {
        guard !isCreating, !stopped else { return false }
        let preferredAccount = request.source?.accountID ?? request.accountID ?? selectedAccountID
        let preferredList = request.listID ?? preferredAccount.flatMap { defaults.string(forKey: listKey($0)) }
        let wasUncertain = uncertainReferences[request.reference] != nil
        isCreating = true
        creationStates[request.reference] = .adding
        pendingCreation = request
        pendingCreation?.accountID = preferredAccount
        pendingCreation?.listID = preferredList
        errorMessage = nil
        notice = nil
        defer {
            isCreating = false
            if creationStates[request.reference] == .adding {
                creationStates[request.reference] = uncertainReferences[request.reference] == nil ? .idle : .uncertain
            }
        }
        await refreshAccounts()
        guard !stopped, let accountID = preferredAccount ?? selectedAccountID,
              let account = accounts.first(where: { $0.id == accountID }) else {
            errorMessage = "The email's account is no longer available."
            return false
        }
        selectAccount(accountID)
        creationOwners[request.reference] = accountID
        pendingCreation?.accountID = accountID
        guard let client = authorizedService(for: accountID) else {
            errorMessage = GoogleTasksModelError.unavailable.errorDescription
            return false
        }
        let access = accountVersions[accountID, default: 0]
        var beganInsert = false
        do {
            let draft = try request.draft(email: account.email)
            let availableLists = try await client.allTaskLists()
            guard validAccount(accountID, access: access) else { return false }
            guard let destination = availableLists.first(where: { $0.id == preferredList }) ?? availableLists.first else {
                throw GoogleTasksModelError.noLists
            }
            pendingCreation?.listID = destination.id
            // Search every list: a task may have been moved in Google's app.
            for list in availableLists {
                let existing = try await client.allTasks(listID: list.id)
                guard validAccount(accountID, access: access) else { return false }
                if existing.contains(where: { ($0.notes ?? "").components(separatedBy: .newlines).contains(request.marker) }) {
                    showDestination(accountID: accountID, lists: availableLists, listID: list.id, tasks: existing)
                    reconcileMarkers(existing, accountID: accountID, listID: list.id)
                    pendingCreation = nil
                    notice = "Already in \(list.title)"
                    return true
                }
            }
            guard uncertainReferences[request.reference] == nil || retryAfterReview else {
                errorMessage = "Google hasn't confirmed whether this task was added. Check Google Tasks before adding it again."
                return false
            }
            guard validAccount(accountID, access: access), !Task.isCancelled else { return false }
            // Persist before sending: quitting or losing the response must never
            // turn the next click into an unreviewed duplicate POST.
            uncertainReferences[request.reference] = accountID
            defaults.set(uncertainReferences, forKey: Self.uncertaintyKey)
            beganInsert = true
            let created = try await client.insertTask(listID: destination.id, draft: draft)
            guard validAccount(accountID, access: access) else { return false }
            creationStates[request.reference] = .added
            confirmedTasks[request.reference] = (GoogleTaskLocation(accountID: accountID, listID: destination.id), created.id)
            uncertainReferences[request.reference] = nil
            defaults.set(uncertainReferences, forKey: Self.uncertaintyKey)
            pendingCreation = nil
            notice = "Added to \(destination.title)"
            if selectedAccountID == accountID {
                showDestination(accountID: accountID, lists: availableLists, listID: destination.id,
                    tasks: selectedListID == destination.id ? [created] + tasks.filter { $0.id != created.id } : [created])
            }
            await refresh()
            return true
        } catch {
            guard validAccount(accountID, access: access) else { return false }
            if beganInsert, GoogleTasksIssue.creationMayHaveSucceeded(error) {
                errorMessage = "Google hasn't confirmed whether this task was added. Refresh before trying again."
            } else {
                if beganInsert || !wasUncertain {
                    uncertainReferences[request.reference] = nil
                    defaults.set(uncertainReferences, forKey: Self.uncertaintyKey)
                }
                if let validation = error as? GoogleTasksModelError { errorMessage = validation.errorDescription }
                else {
                    issue = GoogleTasksIssue(error)
                    errorMessage = "The task wasn't added. \(GoogleTasksIssue(error).message)"
                }
            }
            return false
        }
    }

    func setCompleted(_ task: GoogleTask, completed: Bool) async -> Bool {
        await update(task, update: GoogleTaskUpdate(isCompleted: completed))
    }

    @discardableResult
    func update(_ task: GoogleTask, update: GoogleTaskUpdate, location: GoogleTaskLocation? = nil) async -> Bool {
        guard let target = location ?? selectedLocation else { return false }
        let accountID = target.accountID, listID = target.listID
        let key = busyKey(task.id, location: target)
        guard let client = authorizedService(for: accountID), !busyTaskIDs.contains(key), !stopped else { return false }
        let access = accountVersions[accountID, default: 0]
        busyTaskIDs.insert(key)
        readGeneration += 1
        errorMessage = nil
        defer { busyTaskIDs.remove(key) }
        do {
            let updated = try await client.updateTask(listID: listID, taskID: task.id, update: update, etag: task.etag)
            guard validAccount(accountID, access: access) else { return false }
            if selectedAccountID == accountID, selectedListID == listID,
               let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = updated }
            await refresh()
            return true
        } catch {
            guard validAccount(accountID, access: access), selectedAccountID == accountID, selectedListID == listID else { return false }
            errorMessage = "Couldn't confirm the change. \(GoogleTasksIssue(error).message)"
            issue = GoogleTasksIssue(error)
            await refresh(clearError: false)
            return false
        }
    }

    @discardableResult
    func delete(_ task: GoogleTask, location: GoogleTaskLocation? = nil) async -> Bool {
        guard let target = location ?? selectedLocation else { return false }
        let accountID = target.accountID, listID = target.listID
        let key = busyKey(task.id, location: target)
        guard let client = authorizedService(for: accountID), !busyTaskIDs.contains(key), !stopped else { return false }
        let access = accountVersions[accountID, default: 0]
        busyTaskIDs.insert(key)
        readGeneration += 1
        errorMessage = nil
        defer { busyTaskIDs.remove(key) }
        do {
            try await client.deleteTask(listID: listID, taskID: task.id, etag: task.etag)
            guard validAccount(accountID, access: access) else { return false }
            if selectedAccountID == accountID, selectedListID == listID { tasks.removeAll { $0.id == task.id } }
            for line in (task.notes ?? "").components(separatedBy: .newlines) where line.hasPrefix("Tern task reference: ") {
                creationStates[String(line.dropFirst("Tern task reference: ".count))] = nil
            }
            await refresh()
            return true
        } catch {
            guard validAccount(accountID, access: access), selectedAccountID == accountID, selectedListID == listID else { return false }
            errorMessage = "Couldn't confirm deletion. \(GoogleTasksIssue(error).message)"
            issue = GoogleTasksIssue(error)
            await refresh(clearError: false)
            return false
        }
    }
}
