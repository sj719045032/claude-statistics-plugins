import ClaudeStatisticsKit
import Foundation

/// Thread-safe snapshot of user-visible Codex threads from the canonical
/// `threads` table. `nil` means the database has not been scanned (or is
/// temporarily unavailable), in which case filtering fails open.
final class CodexVisibleThreadIndex: @unchecked Sendable {
    static let shared = CodexVisibleThreadIndex()

    private let lock = NSLock()
    private var threadIDs: Set<String>?

    private init() {}

    func replace(with ids: Set<String>) {
        let normalized = Set(ids.map(Self.normalize))
        lock.lock()
        threadIDs = normalized
        lock.unlock()
    }

    func markUnavailable() {
        lock.lock()
        threadIDs = nil
        lock.unlock()
    }

    func contains(_ sessionID: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return threadIDs?.contains(Self.normalize(sessionID))
    }

    private static func normalize(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum CodexThreadVisibility {
    static func isUserVisible(threadSource: String?, legacySource: String) -> Bool {
        let normalizedThreadSource = threadSource?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let normalizedThreadSource, !normalizedThreadSource.isEmpty {
            return normalizedThreadSource == "user"
        }

        let normalizedLegacySource = legacySource
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedLegacySource == "cli" || normalizedLegacySource == "vscode"
    }
}

/// Codex.app creates internal jobs for features such as ambient suggestions
/// and approval assessment. They emit normal hooks, but Codex's canonical
/// `threads` table either omits them or marks them as non-user threads. Filter
/// by that structured identity instead of matching mutable prompt text.
struct CodexVisibleThreadFilter: SessionEventFilter {
    let id = "codex.visible-thread"

    func shouldDisplay(_ context: SessionFilterContext) -> Bool {
        guard context.providerId == "codex",
              let terminalName = context.terminalName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
              terminalName == "codex" || terminalName == "codex.app" else {
            return true
        }

        return CodexVisibleThreadIndex.shared.contains(context.sessionId) ?? true
    }
}
