import AppKit
import ClaudeStatisticsKit
import Foundation

/// Ghostty plugin (extracted from host module's
/// `BuiltinTerminalPlugins.GhosttyPlugin` + `GhosttyTerminalCapability`
/// during catalog-source migration). Self-contained — owns its own
/// AppleScript focus / launch / probe logic.
///
/// **Note**: the host's `TerminalFocusIdentityProviding` capability
/// (custom stable-id caching decisions) is not yet exposed through
/// the SDK so this plugin falls back to the host coordinator's
/// default caching behaviour (`?? true`). Stable-id caching for
/// Ghostty is a follow-up SDK extension; the focus path itself
/// (window/tab/project-path matching) is unchanged.
@objc(GhosttyPlugin)
public final class GhosttyPlugin: NSObject, TerminalPlugin {
    public static let manifest = PluginManifest(
        id: "com.mitchellh.ghostty",
        kind: .terminal,
        displayName: "Ghostty",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [.appleScript],
        principalClass: "GhosttyPlugin"
    )

    public let descriptor = TerminalDescriptor(
        id: "Ghostty",
        displayName: "Ghostty",
        category: .terminal,
        bundleIdentifiers: ["com.mitchellh.ghostty"],
        terminalNameAliases: ["ghostty", "xterm-ghostty"],
        processNameHints: ["ghostty"],
        focusPrecision: .bestEffort,
        autoLaunchPriority: 10
    )

    public override init() { super.init() }

    public func detectInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil
    }

    public func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        GhosttyFocusStrategy()
    }

    public func makeLauncher() -> (any TerminalLauncher)? {
        GhosttyLauncher()
    }

    public func makeReadinessProvider() -> (any TerminalReadinessProviding)? {
        GhosttyReadinessProvider()
    }
}

// MARK: - Context enrichment

extension GhosttyPlugin: TerminalContextEnriching {
    /// Ghostty doesn't export a per-surface env var, so the host has
    /// no env-only path to recover its window/tab/stable IDs. The
    /// plugin uses AppleScript to ask the running app for either
    /// (a) the frontmost terminal whose cwd matches the hook's cwd,
    /// or (b) — when (a) is too eager — the unique window whose cwd
    /// matches. Cheap-event gating keeps high-frequency hook events
    /// from spamming osascript on every PreToolUse.
    public func enrichContext(
        event: String,
        cwd: String?,
        env: [String: String]
    ) -> HookTerminalContext? {
        let frontmostEvents: Set<String> = ["SessionStart", "UserPromptSubmit"]
        if frontmostEvents.contains(event),
           let frontmost = ghosttyFrontmostContext(cwd: cwd) {
            return frontmost
        }
        return ghosttyUniqueDirectoryMatch(cwd: cwd)
    }
}

private func ghosttyFrontmostContext(cwd: String?) -> HookTerminalContext? {
    let script = """
    tell application id "com.mitchellh.ghostty"
        try
            set w to front window
            set tabRef to selected tab of w
            set terminalRef to focused terminal of tabRef
            set outputLine to (id of w as text) & (ASCII character 31) & (id of tabRef as text) & (ASCII character 31) & (id of terminalRef as text) & (ASCII character 31) & (working directory of terminalRef as text)
            return outputLine
        end try
    end tell
    return ""
    """

    guard let output = GhosttyScriptRunner.run(script) else {
        DiagnosticLogger.shared.verbose(
            "GhosttyContextEnricher frontmost osascript failed cwd=\(cwd ?? "-")"
        )
        return nil
    }

    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = trimmed.split(separator: "\u{1F}", omittingEmptySubsequences: false)
    guard parts.count == 4 else {
        DiagnosticLogger.shared.verbose(
            "GhosttyContextEnricher frontmost parse mismatch fields=\(parts.count) raw=\(trimmed.debugDescription)"
        )
        return nil
    }

    let resolvedCWD = ghosttyNormalizePath(cwd)
    let resolvedTerminalCWD = ghosttyNormalizePath(String(parts[3]))
    guard resolvedTerminalCWD == resolvedCWD else {
        DiagnosticLogger.shared.verbose(
            "GhosttyContextEnricher frontmost cwd mismatch hook=\(resolvedCWD ?? "-") ghostty=\(resolvedTerminalCWD ?? "-")"
        )
        return nil
    }

    DiagnosticLogger.shared.verbose(
        "GhosttyContextEnricher frontmost matched window=\(String(parts[0])) tab=\(String(parts[1])) stable=\(String(parts[2])) cwd=\(resolvedTerminalCWD ?? "-")"
    )
    return HookTerminalContext(
        socket: nil,
        windowID: String(parts[0]).nilIfEmpty,
        tabID: String(parts[1]).nilIfEmpty,
        surfaceID: String(parts[2]).nilIfEmpty
    )
}

private func ghosttyUniqueDirectoryMatch(cwd: String?) -> HookTerminalContext? {
    let script = """
    tell application id "com.mitchellh.ghostty"
        set outputLines to {}
        repeat with w in every window
            set windowID to id of w as text
            repeat with tabRef in every tab of w
                set tabID to id of tabRef as text
                set terminalRef to focused terminal of tabRef
                set terminalID to id of terminalRef as text
                set terminalWD to working directory of terminalRef as text
                set end of outputLines to windowID & (ASCII character 31) & tabID & (ASCII character 31) & terminalID & (ASCII character 31) & terminalWD
            end repeat
        end repeat
        set AppleScript's text item delimiters to linefeed
        set outputText to outputLines as text
        set AppleScript's text item delimiters to ""
        return outputText
    end tell
    """

    guard let output = GhosttyScriptRunner.run(script) else {
        return nil
    }

    let target = ghosttyNormalizePath(cwd)
    var matches: [HookTerminalContext] = []
    for line in output.split(whereSeparator: \.isNewline) {
        let parts = line.split(separator: "\u{1F}", omittingEmptySubsequences: false)
        guard parts.count == 4 else { continue }
        guard ghosttyNormalizePath(String(parts[3])) == target else { continue }
        matches.append(
            HookTerminalContext(
                socket: nil,
                windowID: String(parts[0]).nilIfEmpty,
                tabID: String(parts[1]).nilIfEmpty,
                surfaceID: String(parts[2]).nilIfEmpty
            )
        )
    }

    DiagnosticLogger.shared.verbose(
        "GhosttyContextEnricher unique cwd scan target=\(target ?? "-") matches=\(matches.count)"
    )
    return matches.count == 1 ? matches[0] : nil
}

private func ghosttyNormalizePath(_ value: String?) -> String? {
    guard let value else { return nil }
    var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }

    if text.hasPrefix("file://") {
        if let decoded = URL(string: text)?.path.removingPercentEncoding {
            text = decoded
        } else {
            text = String(text.dropFirst(7))
        }
    }

    return URL(fileURLWithPath: text)
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path
}

// MARK: - Launcher

private struct GhosttyLauncher: TerminalLauncher {
    func launch(_ request: TerminalLaunchRequest) {
        // Bootstrap via a tiny script that Ghostty "opens" through the
        // macOS open-doc Apple Event. The script MUST live under
        // `request.cwd`: Ghostty uses the file's parent directory as
        // the new tab's working directory, so dropping it anywhere
        // else (e.g. ~/.claude-statistics/run) leaves the tab in the
        // wrong cwd and breaks every cwd-based focus/match path
        // downstream.
        let expandedCwd = (request.cwd as NSString).expandingTildeInPath
        let scriptPath = (expandedCwd as NSString).appendingPathComponent(".cs-launch")
        let content = """
        #!/bin/zsh -l
        rm -f \(TerminalShellCommand.escape(scriptPath))
        cd \(TerminalShellCommand.escape(expandedCwd)) || exit 1
        exec \(request.commandOnly)
        """
        guard (try? content.write(toFile: scriptPath, atomically: true, encoding: .utf8)) != nil,
              (try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)) != nil
        else { return }

        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty")
            ?? URL(fileURLWithPath: "/Applications/Ghostty.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: scriptPath)],
            withApplicationAt: appURL,
            configuration: configuration
        )
    }
}

// MARK: - Focus strategy

private struct GhosttyFocusStrategy: TerminalFocusStrategy {
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
        guard let output = GhosttyScriptRunner.run(script) else { return nil }
        return parseFocusOutput(output, fallbackStableID: target.terminalStableID)
    }

    func resolvedFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        await directFocus(target: target)
    }

    /// Ghostty's focus script returns `"ok|<stableID>"` instead of
    /// the plain `"ok"` other terminals use. Parse that round-trip
    /// here so the host coordinator can cache the resolved stable id.
    private func parseFocusOutput(_ output: String, fallbackStableID: String?) -> TerminalFocusExecutionResult? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ok") else { return nil }
        let parts = trimmed.split(separator: "|", maxSplits: 1).map(String.init)
        let resolvedStableID = parts.count == 2 ? parts[1].nilIfEmpty : fallbackStableID
        return TerminalFocusExecutionResult(capability: .ready, resolvedStableID: resolvedStableID)
    }

    /// Build the AppleScript that walks every window/tab/terminal in
    /// Ghostty looking for a stable id, working directory, or
    /// window/tab id match. Returns nil when no locator is provided.
    private func focusScript(for target: TerminalFocusTarget) -> String? {
        let trimmedWindow = target.terminalWindowID?.nilIfEmpty
        let trimmedTab = target.terminalTabID?.nilIfEmpty
        let trimmedStable = target.terminalStableID?.nilIfEmpty
        let trimmedPath = target.projectPath?.nilIfEmpty

        let hasExplicitLocator = trimmedWindow != nil || trimmedTab != nil || trimmedStable != nil
        guard hasExplicitLocator || trimmedPath != nil else { return nil }

        let stableIDClause: String
        if let trimmedStable {
            stableIDClause = """
            if (id of terminalRef as text) is "\(GhosttyAppleScriptHelpers.escape(trimmedStable))" then
                select tab tabRef
                activate window w
                focus terminalRef
                return "ok|" & (id of terminalRef as text)
            end if
            """
        } else {
            stableIDClause = ""
        }

        let workingDirectoryClause: String
        if trimmedStable == nil {
            workingDirectoryClause = """
            set workingDirText to (working directory of terminalRef as text)
            if my normalizePath(workingDirText) is in targetPaths then
                select tab tabRef
                activate window w
                focus terminalRef
                return "ok|" & (id of terminalRef as text)
            end if
            """
        } else {
            workingDirectoryClause = ""
        }

        let tabFocusClause: String
        if trimmedStable == nil, let trimmedWindow, let trimmedTab {
            tabFocusClause = """
            try
                set targetWindow to first window whose id is "\(GhosttyAppleScriptHelpers.escape(trimmedWindow))"
                set targetTab to first tab of targetWindow whose id is "\(GhosttyAppleScriptHelpers.escape(trimmedTab))"
                activate targetWindow
                set terminalRef to focused terminal of targetTab
                focus terminalRef
                return "ok|" & (id of terminalRef as text)
            end try
            """
        } else if trimmedStable == nil, trimmedPath == nil, let trimmedWindow {
            tabFocusClause = """
            try
                activate (first window whose id is "\(GhosttyAppleScriptHelpers.escape(trimmedWindow))")
                return "ok|"
            end try
            """
        } else {
            tabFocusClause = ""
        }

        return """
        set targetPaths to \(GhosttyAppleScriptHelpers.pathListLiteral(target.projectPath))
        tell application id "com.mitchellh.ghostty"
            activate
            repeat with w in windows
                repeat with tabRef in tabs of w
                    repeat with terminalRef in terminals of tabRef
                        try
                            \(stableIDClause)
                            \(workingDirectoryClause)
                        end try
                    end repeat
                end repeat
            end repeat
            \(tabFocusClause)
        end tell
        return "miss"

        on normalizePath(rawValue)
            set valueText to rawValue as text
            if valueText starts with "file://" then
                set valueText to text 8 thru -1 of valueText
            end if
            set valueText to my decodeURLText(valueText)
            if valueText ends with "/" and valueText is not "/" then
                set valueText to text 1 thru -2 of valueText
            end if
            return valueText
        end normalizePath

        on decodeURLText(valueText)
            set decodedText to valueText
            set decodedText to my replaceText("%20", " ", decodedText)
            set decodedText to my replaceText("%2D", "-", decodedText)
            set decodedText to my replaceText("%2E", ".", decodedText)
            set decodedText to my replaceText("%2F", "/", decodedText)
            set decodedText to my replaceText("%5F", "_", decodedText)
            return decodedText
        end decodeURLText

        on replaceText(findText, replaceText, sourceText)
            set AppleScript's text item delimiters to findText
            set textItems to every text item of sourceText
            set AppleScript's text item delimiters to replaceText
            set rebuiltText to textItems as text
            set AppleScript's text item delimiters to ""
            return rebuiltText
        end replaceText
        """
    }
}

// MARK: - Readiness

private struct GhosttyReadinessProvider: TerminalReadinessProviding {
    func installationStatus() -> TerminalInstallationStatus {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil
            ? .installed : .notInstalled
    }

    func setupRequirements() -> [TerminalRequirement] { [] }

    func setupActions() -> [TerminalSetupAction] {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") else {
            return []
        }
        return [
            TerminalSetupAction(
                id: "ghostty.open",
                title: "Open Ghostty",
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

private enum GhosttyAppleScriptHelpers {
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// AppleScript list of every accepted form of a project path:
    /// raw, standardized, with/without trailing slash, file:// URL.
    /// Returns `"{}"` for nil/empty so the calling script can use
    /// `is in targetPaths` without conditional clauses.
    static func pathListLiteral(_ projectPath: String?) -> String {
        guard let projectPath, !projectPath.isEmpty else { return "{}" }
        let raw = (projectPath as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: raw).standardizedFileURL.path
        let trimmed = trimTrailingSlash(standardized)
        let encoded = URL(fileURLWithPath: trimmed).absoluteString
        let values = [raw, standardized, trimmed, "\(trimmed)/", encoded]
        let unique = Array(Set(values.map(trimTrailingSlash))).sorted()
        return "{\(unique.map { "\"\(escape($0))\"" }.joined(separator: ", "))}"
    }

    private static func trimTrailingSlash(_ value: String) -> String {
        guard value.count > 1, value.hasSuffix("/") else { return value }
        return String(value.dropLast())
    }
}

private enum GhosttyScriptRunner {
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
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
