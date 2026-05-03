import AppKit
import ClaudeStatisticsKit
import Foundation

/// First external Terminal plugin (companion to ClaudeAppPlugin):
/// OpenAI's Codex desktop app.
///
/// Codex.app exposes `codex://threads/<uuid>` natively (the in-app
/// menu literally has a "Copy deeplink" entry), and the Codex CLI
/// rollout filename embeds the same UUID — so the notch click can
/// land directly on the matching thread instead of merely activating
/// the app.
@objc(CodexAppPlugin)
public final class CodexAppPlugin: NSObject, TerminalPlugin {
    /// Distinct from `CodexPluginDogfood` (the provider-side adapter
    /// at `com.openai.codex`) — this `.app` suffix marks the GUI
    /// terminal host so PluginRegistry's id-keyed bookkeeping
    /// (sources, disabled, source(for:)) doesn't collapse the two
    /// instances into one entry. The `descriptor.bundleIdentifiers`
    /// still carry the real macOS bundle id so process tree walking
    /// and focus dispatch resolve correctly against the on-disk app.
    public static let manifest = PluginManifest(
        id: "com.openai.codex.app",
        kind: .terminal,
        displayName: "Codex",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [],
        principalClass: "CodexAppPlugin"
    )

    public let descriptor = TerminalDescriptor(
        id: "com.openai.codex.app",
        displayName: "Codex",
        category: .terminal,
        bundleIdentifiers: ["com.openai.codex"],
        terminalNameAliases: ["codex", "codex.app"],
        processNameHints: ["codex"],
        focusPrecision: .exact,
        autoLaunchPriority: nil,
        boundProviderID: "codex"
    )

    public override init() { super.init() }

    public func detectInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: descriptor.bundleIdentifiers.first ?? "") != nil
    }

    public func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        CodexAppFocusStrategy()
    }

    public func makeLauncher() -> (any TerminalLauncher)? {
        CodexAppLauncher(bundleIdentifiers: Array(descriptor.bundleIdentifiers))
    }

    /// Codex.app fires a fresh `codex-cli` subprocess (with a new
    /// session id) every time it generates "Ambient Suggestions" for
    /// the current project; the prompt is a fixed template the host
    /// app injects. The behaviour is owned by the host (codex-cli
    /// alone never produces these), so the filter ships with this
    /// terminal plugin — install Codex.app, get the filter; remove
    /// it, the rule goes too.
    public func makeSessionFilters() -> [any SessionEventFilter] {
        [
            SyntheticPromptFilter(
                id: "codex-app.ambient-suggestions",
                providerId: "codex",
                prefixes: ["Generate 0 to 3 ambient suggestions"]
            )
        ]
    }
}

struct CodexAppLauncher: TerminalLauncher {
    let bundleIdentifiers: [String]

    func launch(_ request: TerminalLaunchRequest) {
        if request.executable == "codex",
           request.arguments.isEmpty,
           openProject(request.cwd) {
            return
        }

        if request.executable == "codex",
           request.arguments.count == 2,
           request.arguments[0] == "resume",
           let url = URL(string: "codex://threads/\(request.arguments[1])"),
           NSWorkspace.shared.open(url) {
            return
        }

        if request.executable == "codex",
           request.arguments.count == 2,
           request.arguments[0] == "resume" {
            copyCommandAndNotify(request, messageKey: "detail.resumeCopiedManual")
            activateCodexApp()
            return
        }

        if request.executable == "codex",
           request.arguments.isEmpty,
           case .newSession = request.intent {
            copyCommandAndNotify(request, messageKey: "detail.newCopiedManual")
            activateCodexApp()
            return
        }

        if let url = URL(string: "codex://"), NSWorkspace.shared.open(url) {
            return
        }

        activateCodexApp()
    }

    private func openProject(_ path: String) -> Bool {
        guard let appURL = appURL() else { return false }

        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: expanded, isDirectory: true)],
            withApplicationAt: appURL,
            configuration: configuration
        )
        activateCodexApp()
        return true
    }

    private func copyCommandAndNotify(_ request: TerminalLaunchRequest, messageKey: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(request.commandInWorkingDirectory, forType: .string)
        TerminalDispatch.notify(NSLocalizedString(messageKey, comment: ""))
    }

    private func activateCodexApp() {
        if let running = bundleIdentifiers
            .lazy
            .flatMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0) })
            .first {
            running.unhide()
            _ = running.activate(options: [.activateAllWindows])
            return
        }

        guard let appURL = appURL() else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }

    private func appURL() -> URL? {
        bundleIdentifiers
            .lazy
            .compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
            .first
    }
}

struct CodexAppFocusStrategy: TerminalFocusStrategy {
    func capability(for target: TerminalFocusTarget) -> TerminalFocusCapability {
        target.sessionId?.isEmpty == false ? .ready : .appOnly
    }

    func directFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        await activate(sessionId: target.sessionId)
    }

    func resolvedFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        await activate(sessionId: target.sessionId)
    }

    @MainActor
    private func activate(sessionId: String?) -> TerminalFocusExecutionResult {
        if let sessionId, !sessionId.isEmpty,
           let url = URL(string: "codex://threads/\(sessionId)"),
           NSWorkspace.shared.open(url) {
            return TerminalFocusExecutionResult(capability: .ready, resolvedStableID: sessionId)
        }
        if let url = URL(string: "codex://"), NSWorkspace.shared.open(url) {
            return TerminalFocusExecutionResult(capability: .appOnly, resolvedStableID: nil)
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            return TerminalFocusExecutionResult(capability: .appOnly, resolvedStableID: nil)
        }
        return TerminalFocusExecutionResult(capability: .unresolved, resolvedStableID: nil)
    }
}
