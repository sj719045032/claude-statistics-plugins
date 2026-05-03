import AppKit
import ClaudeStatisticsKit
import Foundation

/// Trae editor plugin (ByteDance's VSCode fork). Trae ships multiple
/// regional app bundles; keep the identifiers together so detection,
/// focus and project-open all resolve through the installed variant.
@objc(TraePlugin)
public final class TraePlugin: NSObject, TerminalPlugin {
    public static let manifest = PluginManifest(bundle: Bundle(for: TraePlugin.self))!

    public let descriptor = TerminalDescriptor(
        id: "com.trae.app",
        displayName: "Trae",
        category: .editor,
        bundleIdentifiers: [
            "com.trae.app",
            "cn.trae.app"
        ],
        terminalNameAliases: [
            "trae",
            "trae-cn",
            "trae cn",
            "marscode"
        ],
        processNameHints: [
            "trae",
            "trae-cn",
            "trae cn",
            "marscode"
        ],
        focusPrecision: .appOnly,
        autoLaunchPriority: nil
    )

    private var bundleIDs: [String] {
        ["com.trae.app", "cn.trae.app"]
    }

    public override init() { super.init() }

    public func detectInstalled() -> Bool {
        bundleIDs.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    public func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        ActivateAppFocusStrategy(bundleIdentifiers: bundleIDs)
    }

    public func makeLauncher() -> (any TerminalLauncher)? {
        OpenInEditorLauncher(bundleIdentifiers: bundleIDs)
    }

    public func makeReadinessProvider() -> (any TerminalReadinessProviding)? {
        EditorReadinessProvider(
            bundleIdentifiers: bundleIDs,
            displayName: "Trae",
            actionID: "trae.open"
        )
    }
}
