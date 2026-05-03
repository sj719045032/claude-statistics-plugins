import AppKit
import ClaudeStatisticsKit
import Foundation

/// First external Terminal plugin: Anthropic's Claude desktop app.
///
/// The host's `ProcessTreeWalker` ascends the parent process chain at
/// notch-click time looking for a "terminal-like" bundle to activate.
/// Sessions started from inside Claude.app would otherwise stop at a
/// non-terminal ancestor and the click went nowhere ("空岛"). This
/// plugin teaches the host that `com.anthropic.claudefordesktop` is a
/// valid focus target. Claude Desktop's public docs cover new Code
/// sessions, but not a stable Code-session resume deep link; resume and
/// focus therefore activate the app instead of pretending we can land on
/// an exact project.
@objc(ClaudeAppPlugin)
public final class ClaudeAppPlugin: NSObject, TerminalPlugin {
    public static let manifest = PluginManifest(
        id: "com.anthropic.claudefordesktop",
        kind: .terminal,
        displayName: "Claude",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [],
        principalClass: "ClaudeAppPlugin"
    )

    public let descriptor = TerminalDescriptor(
        id: "com.anthropic.claudefordesktop",
        displayName: "Claude",
        category: .terminal,
        bundleIdentifiers: ["com.anthropic.claudefordesktop"],
        terminalNameAliases: ["claude", "claude.app"],
        processNameHints: ["claude"],
        focusPrecision: .appOnly,
        autoLaunchPriority: nil,
        boundProviderID: "claude"
    )

    public override init() { super.init() }

    public func detectInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: descriptor.bundleIdentifiers.first ?? "") != nil
    }

    public func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        ClaudeAppFocusStrategy()
    }

    public func makeLauncher() -> (any TerminalLauncher)? {
        ClaudeAppLauncher(bundleIdentifiers: Array(descriptor.bundleIdentifiers))
    }
}

struct ClaudeAppLauncher: TerminalLauncher {
    let bundleIdentifiers: [String]

    func launch(_ request: TerminalLaunchRequest) {
        DiagnosticLogger.shared.info(
            "Claude app launch executable=\(request.executable) arguments=\(request.arguments.joined(separator: " ")) cwd=\(request.cwd)"
        )

        if request.executable == "claude",
           let sessionID = resumeSessionID(from: request.arguments) {
            copyCommandAndNotify(request, messageKey: "detail.resumeCopiedManual")
            let activated = activateClaudeApp()
            DiagnosticLogger.shared.info("Claude app launch resume fallback session=\(sessionID) activate=\(activated)")
            return
        }

        if request.executable == "claude",
           request.arguments.isEmpty,
           openClaudeCodeNew(folder: request.cwd) {
            let activated = activateClaudeApp()
            DiagnosticLogger.shared.info("Claude app launch opened new session cwd=\(request.cwd) activate=\(activated)")
            return
        }

        if request.executable == "claude",
           request.arguments.isEmpty,
           case .newSession = request.intent {
            copyCommandAndNotify(request, messageKey: "detail.newCopiedManual")
            _ = activateClaudeApp()
            return
        }

        if let url = URL(string: "claude://"), NSWorkspace.shared.open(url) {
            return
        }

        _ = activateClaudeApp()
    }

    private func openClaudeCodeNew(folder: String) -> Bool {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/new"
        components.queryItems = [
            URLQueryItem(name: "folder", value: folder)
        ]

        guard let url = components.url else { return false }
        return NSWorkspace.shared.open(url)
    }

    private func resumeSessionID(from arguments: [String]) -> String? {
        guard arguments.count == 2,
              ["--resume", "-r", "resume"].contains(arguments[0]),
              !arguments[1].isEmpty
        else {
            return nil
        }
        return arguments[1]
    }

    private func copyCommandAndNotify(_ request: TerminalLaunchRequest, messageKey: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(request.commandInWorkingDirectory, forType: .string)
        TerminalDispatch.notify(NSLocalizedString(messageKey, comment: ""))
    }

    private func activateClaudeApp() -> Bool {
        if let running = bundleIdentifiers
            .lazy
            .flatMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0) })
            .first {
            running.unhide()
            let activated = running.activate(options: [.activateAllWindows])
            let reopened = running.bundleIdentifier.map { runAppleScript(command: "reopen", bundleIdentifier: $0) } ?? false
            let appleActivated = running.bundleIdentifier.map { runAppleScript(command: "activate", bundleIdentifier: $0) } ?? false
            return activated || reopened || appleActivated
        }

        guard let appURL = bundleIdentifiers
            .lazy
            .compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
            .first
        else { return false }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        return true
    }

    private func runAppleScript(command: String, bundleIdentifier: String) -> Bool {
        let escaped = bundleIdentifier
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application id \"\(escaped)\" to \(command)"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        script.executeAndReturnError(&error)
        if let error {
            DiagnosticLogger.shared.warning("Claude app launch AppleScript \(command) failed error=\(error)")
            return false
        }
        return true
    }
}

struct ClaudeAppFocusStrategy: TerminalFocusStrategy {
    private let bundleIdentifier = "com.anthropic.claudefordesktop"

    func capability(for target: TerminalFocusTarget) -> TerminalFocusCapability {
        .appOnly
    }

    func directFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        await activate(sessionId: target.sessionId)
    }

    func resolvedFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        await activate(sessionId: target.sessionId)
    }

    @MainActor
    private func activate(sessionId: String?) -> TerminalFocusExecutionResult {
        let activated = activateClaudeApp()
        DiagnosticLogger.shared.info(
            "Claude app focus result session=\(sessionId ?? "-") mode=activateOnly activate=\(activated)"
        )

        if let url = URL(string: "claude://"), NSWorkspace.shared.open(url) {
            _ = activateClaudeApp()
            return TerminalFocusExecutionResult(capability: .appOnly, resolvedStableID: nil)
        }

        return activated
            ? TerminalFocusExecutionResult(capability: .appOnly, resolvedStableID: nil)
            : TerminalFocusExecutionResult(capability: .unresolved, resolvedStableID: nil)
    }

    @MainActor
    private func activateClaudeApp() -> Bool {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            app.unhide()
            let activated = app.activate(options: [.activateAllWindows])
            let reopened = runAppleScript(command: "reopen")
            let appleScriptActivated = runAppleScript(command: "activate")
            return activated || reopened || appleScriptActivated
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        return true
    }

    @MainActor
    private func runAppleScript(command: String) -> Bool {
        let source = "tell application id \"\(bundleIdentifier)\" to \(command)"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        script.executeAndReturnError(&error)
        if let error {
            DiagnosticLogger.shared.warning("Claude app focus AppleScript \(command) failed error=\(error)")
            return false
        }
        return true
    }
}
