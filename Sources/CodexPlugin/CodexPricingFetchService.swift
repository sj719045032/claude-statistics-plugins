import Foundation
import ClaudeStatisticsKit

/// Fetches GPT / Codex pricing from OpenAI's official pricing docs page
/// and parses every model row into structured rates.
///
/// The page is server-rendered HTML: once tags are stripped, each model
/// renders as a flat row
///
///   "<model-id> $<input> $<cached> $<output> …extra tier columns…"
///
/// The same model id appears in several tables (standard, then batch /
/// priority tiers). The **first** occurrence is the standard rate, so we
/// keep only the first match per id. Cells can be a dash ("-"/"—") when a
/// model has no cached-input rate (e.g. the `-pro` models), which we treat
/// as "fall back to 10% of input".
final class CodexPricingFetchService: ProviderPricingFetching {
    static let shared = CodexPricingFetchService()

    private let pricingURL = "https://developers.openai.com/api/docs/pricing"

    private init() {}

    func fetchPricing() async throws -> [String: ModelPricingRates] {
        guard let url = URL(string: pricingURL) else {
            throw PricingFetchError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw PricingFetchError.httpError
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw PricingFetchError.parseError("Cannot decode response")
        }

        return try parsePricingFromHTML(html)
    }

    func parsePricingFromHTML(_ html: String) throws -> [String: ModelPricingRates] {
        let compact = html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#36;", with: "$")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        // A price cell is either "$<number>" or a dash placeholder ("-"/"—"/"–").
        let cell = #"(?:\$([0-9][0-9.]*)|[—–-])"#
        // Model id (gpt-5, gpt-5.5, gpt-5.3-codex, gpt-5.5-pro, …) followed by
        // its first three columns: input, cached input, output.
        let pattern = #"(gpt-[0-9][0-9a-z.\-]*)\s+"# + cell + #"\s+"# + cell + #"\s+"# + cell

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw PricingFetchError.parseError("Invalid pricing regex")
        }

        var results: [String: ModelPricingRates] = [:]
        let ns = compact as NSString

        regex.enumerateMatches(in: compact, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match = match else { return }
            let id = ns.substring(with: match.range(at: 1))
            // Keep the first (standard-rate) row only; later rows are batch /
            // priority tiers for the same model.
            guard results[id] == nil else { return }

            func number(_ index: Int) -> Double? {
                let range = match.range(at: index)
                guard range.location != NSNotFound else { return nil }
                return Double(ns.substring(with: range))
            }

            // group 2 = input, group 3 = cached input, group 4 = output
            guard let input = number(2), let output = number(4) else { return }
            let cachedInput = number(3) ?? input * 0.1

            // OpenAI bills cached-input reads at a discount and has no separate
            // cache-write tier, so map cache-write to the plain input rate and
            // cache-read to the cached-input rate.
            results[id] = ModelPricingRates(
                input: input,
                output: output,
                cacheWrite5m: input,
                cacheWrite1h: input,
                cacheRead: cachedInput
            )
        }

        guard !results.isEmpty else {
            throw PricingFetchError.parseError("No OpenAI pricing data found")
        }

        return results
    }
}
