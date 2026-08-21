import AppKit
import ClaudeStatisticsKit
import Foundation

/// Termius terminal plugin.
///
/// Termius' local-shell tabs host Claude Code / Codex / Gemini exactly
/// like any other terminal, but until something claims the bundle id
/// the host drops every hook they emit: `HookRunner`'s source-side
/// host-claim filter exits before socket I/O for any non-permission
/// payload whose `__CFBundleIdentifier` isn't in
/// `installed-terminal-bundles.txt`, and `AttentionBridge` applies the
/// same rule again for unclaimed hosts. The visible symptom is a
/// Termius user seeing session stats accumulate normally while no
/// notch card ever appears — not even "task finished".
///
/// Only the direct-download build is declared. The Mac App Store build
/// is sandboxed and ships without Local Terminal (per Termius'
/// installation docs), so it can't host a CLI session in the first
/// place and would never emit a hook.
///
/// Termius is Electron and exposes no AppleScript dictionary and no
/// per-tab CLI handle — its sole automation surface is the `termius://`
/// URL scheme, which addresses saved SSH hosts rather than an open
/// local shell. Focus return is therefore app-level activation via the
/// SDK's shared `ActivateAppFocusStrategy`, and no launcher is offered:
/// there is no supported way to open a new local tab running a given
/// command, so Termius stays out of the launch picker
/// (`autoLaunchPriority: nil`) instead of pretending otherwise.
@objc(TermiusPlugin)
public final class TermiusPlugin: NSObject, TerminalPlugin {
    public static let manifest = PluginManifest(bundle: Bundle(for: TermiusPlugin.self))!

    public let descriptor = TerminalDescriptor(
        id: "com.termius-dmg.mac",
        displayName: "Termius",
        category: .terminal,
        bundleIdentifiers: ["com.termius-dmg.mac"],
        // Termius exports `TERM_PROGRAM=Termius`, which the registry
        // normalises to "termius" before lookup.
        terminalNameAliases: ["termius"],
        processNameHints: ["termius"],
        focusPrecision: .appOnly,
        autoLaunchPriority: nil
    )

    public override init() { super.init() }

    public func detectInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: descriptor.bundleIdentifiers.first!) != nil
    }

    public func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        ActivateAppFocusStrategy(bundleIdentifiers: Array(descriptor.bundleIdentifiers))
    }

    public func makeReadinessProvider() -> (any TerminalReadinessProviding)? {
        EditorReadinessProvider(
            bundleIdentifiers: Array(descriptor.bundleIdentifiers),
            displayName: "Termius",
            actionID: "termius.open"
        )
    }
}
