import AppKit
import ClaudeStatisticsKit
import Foundation

/// iTerm2 plugin (extracted from host module's
/// `BuiltinTerminalPlugins.ITermPlugin` + `ITermTerminalCapability`
/// during catalog-source migration). Self-contained — owns its own
/// AppleScript focus / launch / probe logic instead of routing
/// through the host's `AppleScriptFocuser` + `TerminalRegistry`
/// registry. Same osascript bodies as the original host capability
/// struct; only the dispatch layer is inlined.
@objc(ITermPlugin)
public final class ITermPlugin: NSObject, TerminalPlugin {
    public static let manifest = PluginManifest(
        id: "com.googlecode.iterm2",
        kind: .terminal,
        displayName: "iTerm2",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [.appleScript],
        principalClass: "ITermPlugin"
    )

    public let descriptor = TerminalDescriptor(
        id: "iTerm2",
        displayName: "iTerm2",
        category: .terminal,
        bundleIdentifiers: ["com.googlecode.iterm2"],
        terminalNameAliases: ["iterm", "iterm.app", "iterm2"],
        processNameHints: ["iterm"],
        focusPrecision: .exact,
        autoLaunchPriority: 30
    )

    public override init() { super.init() }

    public func detectInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
    }

    public func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        ITermFocusStrategy()
    }

    public func makeLauncher() -> (any TerminalLauncher)? {
        ITermLauncher()
    }

    public func makeReadinessProvider() -> (any TerminalReadinessProviding)? {
        ITermReadinessProvider()
    }
}

// MARK: - Launcher

private struct ITermLauncher: TerminalLauncher {
    func launch(_ request: TerminalLaunchRequest) {
        let command = TerminalShellCommand.escapeAppleScript(request.commandInWorkingDirectory)
        // Prefer opening a new tab in the current window to avoid
        // piling up windows. Fall back to `create window` only when
        // iTerm has none.
        let script = """
        tell application "iTerm"
            activate
            if (count of windows) > 0 then
                tell current window
                    create tab with default profile
                end tell
                tell current session of current window
                    write text "\(command)"
                end tell
            else
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "\(command)"
                end tell
            end if
        end tell
        """
        ITermScriptRunner.fireAndForget(script)
    }
}

// MARK: - Focus strategy

private struct ITermFocusStrategy: TerminalFocusStrategy {
    func capability(for target: TerminalFocusTarget) -> TerminalFocusCapability {
        let hasLocator = target.tty != nil
            || target.projectPath != nil
            || target.terminalWindowID != nil
            || target.terminalTabID != nil
            || target.terminalStableID != nil
        return hasLocator ? .ready : .appOnly
    }

    func directFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        guard let script = focusScript(for: target) else { return nil }
        guard let output = ITermScriptRunner.run(script) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "ok" else { return nil }
        return TerminalFocusExecutionResult(capability: .ready, resolvedStableID: target.terminalStableID)
    }

    func resolvedFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        // No richer fallback for iTerm2 — directFocus is already the
        // most accurate path we have.
        await directFocus(target: target)
    }

    /// Compose the AppleScript that walks every window/tab/session
    /// looking for a match by stable id (preferred) or tty (fallback).
    private func focusScript(for target: TerminalFocusTarget) -> String? {
        let trimmedTTY = target.tty?.isEmpty == false ? target.tty : nil
        let trimmedStable = target.terminalStableID?.isEmpty == false ? target.terminalStableID : nil
        guard trimmedTTY != nil || trimmedStable != nil else { return nil }

        let stableIDClause: String
        if let trimmedStable {
            stableIDClause = """
            if (id of s as text) is "\(ITermAppleScriptHelpers.escape(trimmedStable))" then
                select s
                select t
                select w
                activate
                return "ok"
            end if
            """
        } else {
            stableIDClause = ""
        }

        let ttyClause: String
        if trimmedTTY != nil {
            ttyClause = """
            if targetTtys contains (tty of s as text) then
                select s
                select t
                select w
                activate
                return "ok"
            end if
            """
        } else {
            ttyClause = ""
        }

        return """
        set targetTtys to \(trimmedTTY.map(ITermAppleScriptHelpers.ttyListLiteral) ?? "{}")
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            \(stableIDClause)
                            \(ttyClause)
                        end try
                    end repeat
                end repeat
            end repeat
        end tell
        return "miss"
        """
    }
}

// MARK: - Readiness

private struct ITermReadinessProvider: TerminalReadinessProviding {
    func installationStatus() -> TerminalInstallationStatus {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
            ? .installed : .notInstalled
    }

    func setupRequirements() -> [TerminalRequirement] { [] }

    func setupActions() -> [TerminalSetupAction] {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") else {
            return []
        }
        return [
            TerminalSetupAction(
                id: "iterm.open",
                title: "Open iTerm2",
                kind: .openApp,
                perform: {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
                    return .none
                }
            )
        ]
    }
}

// MARK: - osascript helpers

/// Mirrors the host's `AppleScriptHelpers` enum for plugin self-
/// containment — string-building primitives shared by `focusScript`.
private enum ITermAppleScriptHelpers {
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func ttyListLiteral(_ tty: String) -> String {
        let trimmed = tty.replacingOccurrences(of: "/dev/", with: "")
        let values = [tty, trimmed, "/dev/\(trimmed)"]
        let unique = Array(Set(values)).sorted()
        return "{\(unique.map { "\"\(escape($0))\"" }.joined(separator: ", "))}"
    }
}

/// Same shape as `AppleTerminalBuiltin`'s runner — kept inline so
/// the plugin builds without any host-side dependency.
private enum ITermScriptRunner {
    static func run(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func fireAndForget(_ source: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            if let script = NSAppleScript(source: source) {
                var err: NSDictionary?
                script.executeAndReturnError(&err)
            }
        }
    }
}
