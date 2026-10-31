import Foundation
import MessageContent
import WebKit

/// Compiles, once, the rule list that blocks every load except inline data.
/// Rule regexes don't support alternation, so each allowed scheme has its own rule.
@MainActor
enum RemoteContentBlocker {
    private static var cached: [Bool: WKContentRuleList] = [:]
    private static var compiling: [Bool: Task<RuleListBox, Never>] = [:]

    static func ruleList(allowsRemoteImages: Bool = false) async -> WKContentRuleList? {
        if let cached = cached[allowsRemoteImages] { return cached }
        if let pending = compiling[allowsRemoteImages] { return await pending.value.list }
        let pending = Task { await compile(allowsRemoteImages: allowsRemoteImages) }
        compiling[allowsRemoteImages] = pending
        let box = await pending.value
        cached[allowsRemoteImages] = box.list
        compiling[allowsRemoteImages] = nil
        return box.list
    }

    private static func compile(allowsRemoteImages: Bool) async -> RuleListBox {
        guard let store = WKContentRuleListStore.default() else { return RuleListBox(list: nil) }
        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^about:"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^data:"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^tern-message:"], "action": ["type": "ignore-previous-rules"]],
        ]
        if allowsRemoteImages {
            rules.append(["trigger": ["url-filter": "^https:", "resource-type": ["image"]], "action": ["type": "ignore-previous-rules"]])
            for pattern in TrackerMatcher.blockedURLPatterns {
                rules.append(["trigger": ["url-filter": pattern], "action": ["type": "block"]])
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules), let encoded = String(data: data, encoding: .utf8) else { return RuleListBox(list: nil) }
        return await withCheckedContinuation { (continuation: CheckedContinuation<RuleListBox, Never>) in
            store.compileContentRuleList(forIdentifier: "TernReadingImages-\(allowsRemoteImages)-v1", encodedContentRuleList: encoded) { list, _ in
                continuation.resume(returning: RuleListBox(list: list))
            }
        }
    }
}

/// Carries the compiled list out of WebKit's completion handler, which runs on
/// the main thread, back to the main actor that asked for it.
private struct RuleListBox: @unchecked Sendable {
    let list: WKContentRuleList?
}
