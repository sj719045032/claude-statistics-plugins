import Foundation
import ClaudeStatisticsKit

struct GeminiHookInstaller: HookInstalling {
    let providerId: String = "gemini"

    private static let scriptName = "claude-stats-gemini-hook"

    // Per Gemini's hook reference, "ToolPermission" is a `notification_type`
    // value inside Notification events, NOT an event name on its own. The
    // permission notification still fires through the Notification hook.
    private let supportedHookEvents = [
        "BeforeAgent",
        "BeforeTool",
        "BeforeToolSelection",
        "BeforeModel",
        "AfterTool",
        "AfterModel",
        "AfterAgent",
        "SessionStart",
        "SessionEnd",
        "PreCompress",
        "Notification",
    ]

    private var geminiDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".gemini")
    }

    private var hooksDir: String {
        (geminiDir as NSString).appendingPathComponent("hooks")
    }

    private var scriptPath: String {
        (hooksDir as NSString).appendingPathComponent("\(Self.scriptName).py")
    }

    private var commandPath: String {
        HookInstallerUtils.currentHookCommand(providerId: providerId)
    }

    var isInstalled: Bool {
        let targetCommand = commandPath
        let paths = settingsPaths()
        guard !paths.isEmpty else { return false }

        for path in paths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hooks = root["hooks"] as? [String: Any] else {
                return false
            }

            // We check if ALL supported events have the EXACT current command.
            // If even one is missing or has an old path/quoting, we treat it as
            // not installed so that `install()` will refresh everything.
            for event in supportedHookEvents {
                guard let definitions = hooks[event] as? [[String: Any]] else { return false }

                var foundExactMatch = false
                for definition in definitions {
                    guard let inner = definition["hooks"] as? [[String: Any]] else { continue }
                    if inner.contains(where: { ($0["command"] as? String) == targetCommand }) {
                        foundExactMatch = true
                        break
                    }
                }
                if !foundExactMatch { return false }
            }
        }

        return true
    }

    func install() async throws -> HookInstallResult {
        let targetPaths = settingsPaths()
        let snapshots = [
            FileSnapshot.capture(at: scriptPath),
        ] + targetPaths.map(FileSnapshot.capture)

        do {
            for path in targetPaths {
                var root = try readSettingsJSON(at: path) ?? [:]
                var hooks = root["hooks"] as? [String: Any] ?? [:]

                pruneManagedHooks(from: &hooks)

                for event in supportedHookEvents {
                    var definitions = hooks[event] as? [[String: Any]] ?? []
                    definitions.append([
                        "hooks": [[
                            "type": "command",
                            "command": commandPath,
                        ]]
                    ])
                    hooks[event] = definitions
                }

                root["hooks"] = hooks
                try writeSettingsJSON(root, at: path)
            }
            HookInstallerUtils.removeScript(at: scriptPath)
        } catch {
            for snapshot in snapshots {
                try? snapshot.restore()
            }
            throw error
        }

        return .success
    }

    func uninstall() async throws -> HookInstallResult {
        let targetPaths = settingsPaths()
        let snapshots = [
            FileSnapshot.capture(at: scriptPath),
        ] + targetPaths.map(FileSnapshot.capture)

        do {
            HookInstallerUtils.removeScript(at: scriptPath)

            for path in targetPaths where FileManager.default.fileExists(atPath: path) {
                guard var root = try readSettingsJSON(at: path),
                      var hooks = root["hooks"] as? [String: Any] else {
                    throw HookError.jsonParseError
                }

                pruneManagedHooks(from: &hooks)
                if hooks.isEmpty {
                    root.removeValue(forKey: "hooks")
                } else {
                    root["hooks"] = hooks
                }

                try writeSettingsJSON(root, at: path)
            }
        } catch {
            for snapshot in snapshots {
                try? snapshot.restore()
            }
            throw error
        }

        return .success
    }

    private func readSettingsJSON(at path: String) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookError.jsonParseError
        }
        return root
    }

    private func writeSettingsJSON(_ root: [String: Any], at path: String) throws {
        let fm = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func settingsPaths() -> [String] {
        var paths: [String] = [GeminiAuthStore.settingsPath(forHomePath: geminiDir)]
        let fm = FileManager.default
        let rootURL = managedHomesRootURL()
        if let contents = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for candidate in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey]),
                      values.isDirectory == true else { continue }
                paths.append(GeminiAuthStore.settingsPath(forHomePath: candidate.path))
            }
        }

        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    private func managedHomesRootURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("ClaudeStatistics", isDirectory: true)
            .appendingPathComponent("managed-gemini-homes", isDirectory: true)
    }

    private func pruneManagedHooks(from hooks: inout [String: Any]) {
        for (event, value) in hooks {
            guard let definitions = value as? [[String: Any]] else { continue }
            let sanitized = definitions.compactMap { definition -> [String: Any]? in
                guard let inner = definition["hooks"] as? [[String: Any]] else {
                    return definition
                }

                let retained = inner.filter {
                    !isManagedHookCommand($0["command"] as? String ?? "")
                }
                guard !retained.isEmpty else { return nil }

                var updated = definition
                updated["hooks"] = retained
                return updated
            }

            if sanitized.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = sanitized
            }
        }
    }

    private func isManagedHookCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.contains("--claude-stats-hook-provider \(providerId)") else {
            return false
        }

        if trimmed == commandPath {
            return true
        }

        for channel in runtimeChannels {
            let root = (NSHomeDirectory() as NSString).appendingPathComponent(channel.rootFolderName)
            if trimmed.contains("\(root)/") || trimmed.contains("\(HookInstallerUtils.shellQuoted(root))/") {
                return true
            }

            let wrapperPath = ((root as NSString).appendingPathComponent("bin") as NSString)
                .appendingPathComponent(channel.hookBinaryName)
            if trimmed == "\(wrapperPath) --claude-stats-hook-provider \(providerId)" {
                return true
            }
        }

        return false
    }

    private var runtimeChannels: [(rootFolderName: String, hookBinaryName: String)] {
        [
            (".claude-statistics", "claude-stats-hook"),
            (".claude-statistics-debug", "claude-stats-hook-debug"),
        ]
    }
}
