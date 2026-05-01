import Foundation
import SwiftUI
import ClaudeStatisticsKit

// MARK: - Plugin-scoped i18n

/// Localization helper scoped to this plugin's bundle. Today the
/// plugin lives inside the host bundle so this resolves to
/// `Bundle.main`; once the plugin moves to a standalone `.csplugin`
/// in the catalog repo the same helper will pick up the strings
/// shipped inside that bundle without code changes — `Bundle(for:)`
/// always tracks the class's containing bundle.
private enum GLMPluginLoc {
    private static let bundle = Bundle(for: GLMSubscriptionPlugin.self)

    static func key(_ k: String) -> String {
        bundle.localizedString(forKey: k, value: k, table: nil)
    }

    static func format(_ k: String, _ args: CVarArg...) -> String {
        let format = key(k)
        return String(format: format, locale: .current, arguments: args)
    }
}

// MARK: - Plugin entry point

/// Builtin subscription-extension plugin for GLM Coding Plan
/// (智谱 / Z.ai). Self-contained: contains the plugin manifest, the
/// `SubscriptionAdapter`, the `SubscriptionAccountManager`, and the
/// minimal CLI settings reader the manager needs — nothing depends
/// on host-module types other than the SDK.
///
/// Lives inside the host bundle today (registered via
/// `AppState.hostPluginFactories`) so the out-of-box experience
/// includes GLM. Lifting it out to a standalone `.csplugin` in the
/// catalog repo is a physical move — every reference here is to SDK
/// types, so no host code has to change.
@objc(GLMSubscriptionPlugin)
final class GLMSubscriptionPlugin: NSObject, SubscriptionExtensionPlugin {
    static let manifest = PluginManifest(
        id: "com.bigmodel.glm-subscription",
        kind: .subscriptionExtension,
        displayName: "GLM Coding Plan",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [.filesystemHome, .network],
        principalClass: "GLMSubscriptionPlugin",
        iconAsset: nil,
        category: PluginCatalogCategory.utility
    )

    let targetProviderID: String = "claude"

    @MainActor
    func makeSubscriptionAdapters() -> [any SubscriptionAdapter] {
        [GLMSubscriptionAdapter()]
    }

    override init() { super.init() }
}

// MARK: - Adapter

/// Subscription adapter for GLM Coding Plan endpoints. Hosts
/// `open.bigmodel.cn` / `dev.bigmodel.cn` (智谱清言) and `api.z.ai`
/// (Z.ai international) — they share one quota backend, so a single
/// adapter handles all three regional fronts.
struct GLMSubscriptionAdapter: SubscriptionAdapter {
    var displayName: String { GLMPluginLoc.key("glm.plan.name") }
    let providerID = "claude"
    static let matchingHostsStatic: Set<String> = [
        "open.bigmodel.cn", "dev.bigmodel.cn", "api.z.ai"
    ]
    var matchingHosts: [String] { Array(Self.matchingHostsStatic) }

    @MainActor
    func makeAccountManager() -> SubscriptionAccountManager? {
        GLMSubscriptionAccountManager()
    }

    /// TEMP: when true, skip the real GLM API call and return a
    /// canned `SubscriptionInfo` so the UI can be reviewed without a
    /// live coding plan. Flip to `false` for production builds.
    private static let useMockData = false

    func fetchSubscription(context: SubscriptionContext) async throws -> SubscriptionInfo {
        if Self.useMockData {
            DiagnosticLogger.shared.warning("GLM adapter: returning MOCK data")
            return Self.mockedSubscriptionInfo()
        }
        guard let baseURL = context.baseURL else {
            throw GLMAdapterError.missingBaseURL
        }
        guard let apiKey = context.apiKey, !apiKey.isEmpty else {
            throw GLMAdapterError.missingAPIKey
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let host = components.host else {
            throw GLMAdapterError.invalidBaseURL
        }
        components.path = "/api/monitor/usage/quota/limit"
        components.query = nil
        guard let endpoint = components.url else { throw GLMAdapterError.invalidBaseURL }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GLMAdapterError.transport }
        guard (200..<300).contains(http.statusCode) else {
            throw GLMAdapterError.httpStatus(http.statusCode)
        }
        if let raw = String(data: data, encoding: .utf8) {
            let trimmed = raw.count > 600 ? String(raw.prefix(600)) + "…" : raw
            DiagnosticLogger.shared.info("GLM quota/limit raw response: \(trimmed)")
        }
        let decoded = try JSONDecoder().decode(QuotaLimitEnvelope.self, from: data)
        let limits = decoded.data?.limits ?? []

        let dashboardURL: URL? = {
            if host.contains("z.ai") { return URL(string: "https://z.ai/manage-apikey/usage") }
            return URL(string: "https://\(host)")
        }()

        if decoded.success == false {
            // Translate well-known server error messages so the
            // banner respects the user's app locale; fall back to
            // the raw server msg only for unknown error shapes.
            let serverMsg = decoded.msg ?? ""
            let lowered = serverMsg.lowercased()
            let note: String
            if lowered.contains("coding plan") || serverMsg.contains("coding plan") {
                note = GLMPluginLoc.key("glm.note.noActivePlan")
            } else if serverMsg.isEmpty {
                note = GLMPluginLoc.key("glm.note.subscriptionNotActive")
            } else {
                note = serverMsg
            }
            return SubscriptionInfo(
                planName: displayName,
                quotas: [],
                dashboardURL: dashboardURL,
                nextResetAt: nil,
                note: note
            )
        }

        let quotas: [SubscriptionQuotaWindow] = limits.map { item in
            let kind = QuotaWindowKind(type: item.type, unit: item.unit)
            let used = item.usage ?? item.currentValue ?? 0
            let computedLimit: Int? = {
                if let usage = item.usage, let remaining = item.remaining {
                    return usage + remaining
                }
                return item.number
            }()
            let resetAt = item.nextResetTime.map { ms in
                Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
            }
            return SubscriptionQuotaWindow(
                id: kind.id,
                title: kind.title,
                used: SubscriptionAmount(value: Double(used), unit: kind.unit),
                limit: computedLimit.map { SubscriptionAmount(value: Double($0), unit: kind.unit) },
                percentage: item.percentage,
                resetAt: resetAt
            )
        }

        return SubscriptionInfo(
            planName: displayName,
            quotas: quotas,
            dashboardURL: dashboardURL,
            nextResetAt: quotas.compactMap(\.resetAt).min()
        )
    }

    static func mockedSubscriptionInfo() -> SubscriptionInfo {
        let now = Date()
        return SubscriptionInfo(
            planName: "GLM Coding Plan (Mock)",
            quotas: [
                SubscriptionQuotaWindow(
                    id: "5h", title: "5h tokens",
                    used: SubscriptionAmount(value: 3_240_000, unit: .tokens),
                    limit: SubscriptionAmount(value: 5_000_000, unit: .tokens),
                    percentage: 64.8,
                    resetAt: now.addingTimeInterval(2 * 3600 + 47 * 60)
                ),
                SubscriptionQuotaWindow(
                    id: "monthly", title: "Monthly calls",
                    used: SubscriptionAmount(value: 287, unit: .requests),
                    limit: SubscriptionAmount(value: 1000, unit: .requests),
                    percentage: 28.7,
                    resetAt: now.addingTimeInterval(15 * 86400)
                )
            ],
            dashboardURL: URL(string: "https://bigmodel.cn/usercenter"),
            nextResetAt: now.addingTimeInterval(2 * 3600 + 47 * 60)
        )
    }
}

// MARK: - Account manager

/// Manages GLM identities for the host's identity picker. Two
/// kinds of identities co-exist:
/// - **Synced-from-CLI**: derived from `~/.claude/settings.json` env
///   (id `synced-cli`). Read-only; user manages it via cc itself.
/// - **App-managed**: entered through the Add-account sheet, stored
///   in macOS Keychain. User can have any number of these and switch
///   between them without touching the cc CLI config.
///
/// The two coexist intentionally: a developer might pin the cc CLI
/// to one workspace's GLM token (sync) but hop to another
/// workspace's token in-app for a quick quota check (app-managed).
@MainActor
final class GLMSubscriptionAccountManager: SubscriptionAccountManager {
    static let kAdapterID = "glm"
    static let kSyncedAccountID = "synced-cli"

    private let store = GLMTokenStore()
    private let activeKeyDefault = "GLMSubscription.activeAccountID.v1"

    init() {
        super.init(
            providerID: "claude",
            adapterID: Self.kAdapterID,
            sourceDisplayName: GLMPluginLoc.key("glm.plan.name")
        )
        refresh()
    }

    /// Rebuild `accounts` from disk (CLI settings + keychain) and
    /// reconcile the persisted active id. Called from init and from
    /// the add/remove flows.
    func refresh() {
        var entries: [SubscriptionAccount] = []
        let cliEndpoint = readClaudeCLIEndpoint()
        let cliBound = cliEndpoint.baseURL.flatMap { $0.host }
            .map { GLMSubscriptionAdapter.matchingHostsStatic.contains($0) } ?? false
        let hasCLISynced = cliBound && cliEndpoint.apiKey != nil
        if hasCLISynced {
            entries.append(SubscriptionAccount(
                id: Self.kSyncedAccountID,
                label: GLMPluginLoc.key("glm.identity.syncedFromCLI"),
                detailLine: GLMPluginLoc.key("glm.identity.syncedDetail"),
                isRemovable: false
            ))
        }
        for record in store.allRecords() {
            let host = record.baseURL.host ?? record.baseURL.absoluteString
            entries.append(SubscriptionAccount(
                id: record.id,
                label: record.label,
                detailLine: GLMPluginLoc.format("glm.identity.appManagedDetail", host),
                isRemovable: true
            ))
        }
        // Reconcile active id: keep persisted choice if the account
        // still exists, otherwise fall back to first available
        // (sync-from-CLI takes precedence) or nil.
        let persistedActive = UserDefaults.standard.string(forKey: activeKeyDefault)
        let validIDs = Set(entries.map(\.id))
        let chosenActive: String? = {
            if let persistedActive, validIDs.contains(persistedActive) { return persistedActive }
            return entries.first?.id
        }()
        setAccounts(entries, active: chosenActive)
    }

    override var activeEndpoint: EndpointInfo? {
        guard let activeID = activeAccountID else { return nil }
        if activeID == Self.kSyncedAccountID {
            return readClaudeCLIEndpoint()
        }
        guard let record = store.record(id: activeID) else { return nil }
        return EndpointInfo(baseURL: record.baseURL, apiKey: record.token)
    }

    override func activate(accountID: String?) {
        super.activate(accountID: accountID)
        if let accountID {
            UserDefaults.standard.set(accountID, forKey: activeKeyDefault)
            // App-managed identities default to *not* touching the cc
            // CLI config — that matches Claude's `.independent` mode
            // semantics. Only when the user has explicitly opted into
            // `GLMAccountModeController.syncToCLI` does activating an
            // app-managed identity also rewrite settings.json so cc
            // follows. The synced-from-CLI identity (`kSyncedAccountID`)
            // is by definition the CLI token already, so we never
            // write for it.
            if accountID != Self.kSyncedAccountID,
               GLMAccountModeController.shared.syncToCLI,
               let record = store.record(id: accountID) {
                try? GLMCLISettingsWriter.applyToCLI(
                    baseURL: record.baseURL,
                    token: record.token
                )
                refresh()
            }
        } else {
            UserDefaults.standard.removeObject(forKey: activeKeyDefault)
        }
    }

    override func remove(accountID: String) async throws {
        guard accountID != Self.kSyncedAccountID else {
            throw GLMAccountError.cannotRemoveSynced
        }
        try store.delete(id: accountID)
        refresh()
    }

    override func makeAddAccountView() -> AnyView {
        AnyView(GLMAddAccountSheet(manager: self))
    }

    override func makeSectionFooterView() -> AnyView? {
        AnyView(GLMSectionFooter(manager: self))
    }

    /// Called by the add-account sheet on Save.
    func addAccount(label: String, token: String, baseURLString: String) throws {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBase = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { throw GLMAccountError.emptyToken }
        // Only validate URL shape — host is intentionally unrestricted
        // so the user can point at any GLM-compatible proxy
        // (regional fronts, internal mirrors, future endpoints) that
        // the bundled `matchingHosts` list doesn't know about. The
        // identity router uses adapter id (not host) when an active
        // identity is set, so unknown hosts still route correctly.
        guard let baseURL = URL(string: trimmedBase),
              let scheme = baseURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              baseURL.host != nil else {
            throw GLMAccountError.invalidBaseURL
        }
        let record = GLMTokenRecord(
            id: UUID().uuidString,
            label: trimmedLabel.isEmpty ? "GLM token" : trimmedLabel,
            token: trimmedToken,
            baseURL: baseURL
        )
        try store.insert(record)
        refresh()
        // Activate the just-added one so the user immediately sees
        // their data.
        activate(accountID: record.id)
    }

    /// Plugin-local CLI settings reader. Duplicates the small amount
    /// of parsing logic in `ClaudeEndpointDetector` so this plugin
    /// stays self-contained — extracting it to the catalog repo
    /// later doesn't pull in any host types.
    private func readClaudeCLIEndpoint() -> EndpointInfo {
        let settingsPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              let parsed = try? JSONDecoder().decode(EnvelopeShape.self, from: data) else {
            return .empty
        }
        let env = parsed.env ?? [:]
        let baseURLString = env["ANTHROPIC_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = baseURLString.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let apiKey = (env["ANTHROPIC_AUTH_TOKEN"] ?? env["ANTHROPIC_API_KEY"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return EndpointInfo(baseURL: baseURL, apiKey: (apiKey?.isEmpty ?? true) ? nil : apiKey)
    }

    private struct EnvelopeShape: Decodable {
        let env: [String: String]?
    }
}

// MARK: - Add-account sheet

private struct GLMAddAccountSheet: View {
    @ObservedObject var manager: GLMSubscriptionAccountManager
    @Environment(\.dismiss) private var dismiss

    /// Tag for the URL-mode picker: well-known presets use their
    /// fully-qualified URL string; "custom" is a sentinel that
    /// reveals the freeform `customBaseURL` field below.
    private static let presetSmartGLM = "https://open.bigmodel.cn/api/anthropic"
    private static let presetZAI = "https://api.z.ai/api/anthropic"
    private static let presetCustom = "__custom__"

    @State private var label = ""
    @State private var token = ""
    @State private var urlMode: String = presetSmartGLM
    @State private var customBaseURL = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(GLMPluginLoc.key("glm.add.title"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text(GLMPluginLoc.key("glm.add.label"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(GLMPluginLoc.key("glm.add.label.placeholder"), text: $label)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(GLMPluginLoc.key("glm.add.token"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField(GLMPluginLoc.key("glm.add.token.placeholder"), text: $token)
                    .textFieldStyle(.roundedBorder)
                if let url = URL(string: "https://bigmodel.cn/usercenter/proj-mgmt/apikeys") {
                    Link(GLMPluginLoc.key("glm.add.dashboardLink"), destination: url)
                        .font(.caption)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(GLMPluginLoc.key("glm.add.baseURL"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $urlMode) {
                    Text(GLMPluginLoc.key("glm.add.baseURL.preset.bigmodel")).tag(Self.presetSmartGLM)
                    Text(GLMPluginLoc.key("glm.add.baseURL.preset.zai")).tag(Self.presetZAI)
                    Text(GLMPluginLoc.key("glm.add.baseURL.preset.custom")).tag(Self.presetCustom)
                }
                .labelsHidden()
                .pickerStyle(.menu)

                if urlMode == Self.presetCustom {
                    TextField(GLMPluginLoc.key("glm.add.baseURL.custom.placeholder"), text: $customBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Text(GLMPluginLoc.key("glm.add.baseURL.custom.hint"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(GLMPluginLoc.key("glm.add.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(GLMPluginLoc.key("glm.add.save")) {
                    do {
                        let baseURL = urlMode == Self.presetCustom ? customBaseURL : urlMode
                        try manager.addAccount(
                            label: label,
                            token: token,
                            baseURLString: baseURL
                        )
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saveDisabled)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var saveDisabled: Bool {
        if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if urlMode == Self.presetCustom,
           customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }
}

// MARK: - Keychain store

/// Token record stored as plain JSON. The cc CLI itself keeps the
/// same token in `~/.claude/settings.json` env in plaintext, so
/// double-wrapping it inside Keychain just produced an unlock prompt
/// on every code-sign change without a meaningful security gain.
private struct GLMTokenRecord: Codable {
    let id: String
    let label: String
    let token: String
    let baseURL: URL
}

/// Plain-file token store at
/// `~/Library/Application Support/Claude Statistics/glm-tokens.json`.
/// File mode 0600 so other users on the machine can't read it; that
/// matches the protection level the cc CLI's `settings.json` already
/// gives the same token.
private struct GLMTokenStore {
    private var fileURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return support
            .appendingPathComponent("Claude Statistics", isDirectory: true)
            .appendingPathComponent("glm-tokens.json")
    }

    private struct StoreFile: Codable {
        var records: [GLMTokenRecord]
    }

    private func load() -> StoreFile {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(StoreFile.self, from: data) else {
            return StoreFile(records: [])
        }
        return decoded
    }

    private func save(_ store: StoreFile) throws {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(store)
        try data.write(to: fileURL, options: .atomic)
        // Restrict to user-only reads so other accounts on this Mac
        // don't end up with the GLM token via a shared filesystem.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    func insert(_ record: GLMTokenRecord) throws {
        var store = load()
        store.records.removeAll { $0.id == record.id }
        store.records.append(record)
        try save(store)
    }

    func delete(id: String) throws {
        var store = load()
        store.records.removeAll { $0.id == id }
        try save(store)
    }

    func record(id: String) -> GLMTokenRecord? {
        load().records.first { $0.id == id }
    }

    func allRecords() -> [GLMTokenRecord] {
        load().records
    }
}

// MARK: - CLI sync mode controller

/// Plugin-local equivalent of `ClaudeAccountModeController`. Tracks
/// whether activating an app-managed GLM identity should also
/// rewrite cc's `~/.claude/settings.json` env.
///
/// Default `false` mirrors Claude's `.independent` mode semantics:
/// app-managed identities are app-only by default, switching them
/// doesn't touch the cc CLI config. The synced-from-CLI identity
/// already reflects whatever cc is using — picking it doesn't
/// "write" anything either, because it just *is* the CLI token.
/// Users who want the third-party-tool behaviour (switching also
/// flips the CLI) flip this on explicitly.
@MainActor
final class GLMAccountModeController: ObservableObject {
    static let shared = GLMAccountModeController()
    private let key = "GLMSubscription.syncToCLI.v1"

    @Published var syncToCLI: Bool {
        didSet {
            UserDefaults.standard.set(syncToCLI, forKey: key)
        }
    }

    private init() {
        // Default `false` (app-only). UserDefaults' missing-Bool
        // default is also `false`, so no special-casing needed.
        self.syncToCLI = UserDefaults.standard.bool(forKey: key)
    }
}

// MARK: - Section footer (Sync-to-CLI toggle)

private struct GLMSectionFooter: View {
    @ObservedObject var manager: GLMSubscriptionAccountManager
    @ObservedObject private var modeController = GLMAccountModeController.shared

    var body: some View {
        HStack(spacing: 6) {
            Toggle(isOn: $modeController.syncToCLI) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(GLMPluginLoc.key("glm.section.syncToCLI"))
                        .font(.system(size: 11, weight: .medium))
                    Text(GLMPluginLoc.key("glm.section.syncToCLI.subtitle"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}

// MARK: - CLI settings writer

/// Safe writer for `~/.claude/settings.json`. Preserves every
/// top-level field and every existing env entry — only
/// `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` are overwritten.
/// A timestamped `.bak.glm` backup is dropped next to the file
/// before each write so a botched merge is recoverable.
private enum GLMCLISettingsWriter {
    private static var settingsURL: URL {
        URL(fileURLWithPath: (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/settings.json"))
    }

    static func applyToCLI(baseURL: URL, token: String) throws {
        let url = settingsURL
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = parsed
        }

        // Backup before modifying so a parse error or accidental
        // overwrite is recoverable. Only one .bak.glm at a time —
        // newer writes overwrite the previous backup.
        let bakURL = url.appendingPathExtension("bak.glm")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: bakURL)
            try? FileManager.default.copyItem(at: url, to: bakURL)
        }

        var env = (dict["env"] as? [String: String]) ?? [:]
        env["ANTHROPIC_BASE_URL"] = baseURL.absoluteString
        env["ANTHROPIC_AUTH_TOKEN"] = token
        dict["env"] = env

        // Ensure parent directory exists (fresh-install case).
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }
}

enum GLMAccountError: LocalizedError {
    case emptyToken
    case invalidBaseURL
    case cannotRemoveSynced
    case storage(message: String)

    var errorDescription: String? {
        switch self {
        case .emptyToken:        return GLMPluginLoc.key("glm.error.emptyToken")
        case .invalidBaseURL:    return GLMPluginLoc.key("glm.error.invalidBaseURL")
        case .cannotRemoveSynced:return GLMPluginLoc.key("glm.error.cannotRemoveSynced")
        case .storage(let m):    return GLMPluginLoc.format("glm.error.storage", m)
        }
    }
}

// MARK: - Window classification

private enum QuotaWindowKind {
    case fiveHourTokens
    case monthlyCalls
    case weeklyTokens

    init(type: String?, unit: Int?) {
        switch (type, unit) {
        case ("TOKENS_LIMIT", 3): self = .fiveHourTokens
        case ("TIME_LIMIT", 5):   self = .monthlyCalls
        default:                  self = .weeklyTokens
        }
    }

    var id: String {
        switch self {
        case .fiveHourTokens: return "5h"
        case .monthlyCalls:   return "monthly"
        case .weeklyTokens:   return "weekly"
        }
    }

    var title: String {
        switch self {
        case .fiveHourTokens: return "5h tokens"
        case .monthlyCalls:   return "Monthly calls"
        case .weeklyTokens:   return "Weekly tokens"
        }
    }

    var unit: SubscriptionUnit {
        switch self {
        case .monthlyCalls: return .requests
        default:            return .tokens
        }
    }
}

// MARK: - Wire types

private struct QuotaLimitEnvelope: Decodable {
    struct DataField: Decodable {
        let limits: [LimitItem]?
        let level: String?
    }
    struct LimitItem: Decodable {
        let type: String?
        let unit: Int?
        let number: Int?
        let usage: Int?
        let currentValue: Int?
        let remaining: Int?
        let percentage: Double
        let nextResetTime: Int64?
    }
    let code: Int?
    let msg: String?
    let data: DataField?
    let success: Bool?
}

enum GLMAdapterError: LocalizedError {
    case missingBaseURL
    case missingAPIKey
    case invalidBaseURL
    case transport
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:  return GLMPluginLoc.key("glm.error.missingBaseURL")
        case .missingAPIKey:   return GLMPluginLoc.key("glm.error.missingAPIKey")
        case .invalidBaseURL:  return GLMPluginLoc.key("glm.error.invalidBaseURL.adapter")
        case .transport:       return GLMPluginLoc.key("glm.error.transport")
        case .httpStatus(let code): return GLMPluginLoc.format("glm.error.httpStatus", code)
        }
    }
}
