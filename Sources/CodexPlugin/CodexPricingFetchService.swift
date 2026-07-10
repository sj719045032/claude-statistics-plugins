import Foundation
import ClaudeStatisticsKit

/// Fetches GPT / Codex pricing from OpenAI's official pricing docs page.
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
        var results: [String: ModelPricingRates] = [:]
        for table in elementContents(named: "table", in: html) {
            guard let headers = columnHeaders(in: table),
                  let modelIndex = headers.firstIndex(of: "model"),
                  let inputIndex = headers.firstIndex(of: "input"),
                  let cachedInputIndex = headers.firstIndex(of: "cached input"),
                  let outputIndex = headers.firstIndex(of: "output") else {
                continue
            }
            let cacheWriteIndex = headers.firstIndex(of: "cache writes")
            let requiredIndex = [modelIndex, inputIndex, cachedInputIndex, outputIndex, cacheWriteIndex ?? 0].max() ?? 0

            for row in elementContents(named: "tr", in: table) {
                let cells = elementContents(named: "td", in: row).map(htmlText)
                guard cells.count > requiredIndex,
                      let modelId = modelId(from: cells[modelIndex]),
                      results[modelId] == nil,
                      let input = dollarValue(cells[inputIndex]),
                      let output = dollarValue(cells[outputIndex]) else {
                    continue
                }

                let cachedInput = dollarValue(cells[cachedInputIndex]) ?? 0
                let cacheWrite = cacheWriteIndex.flatMap { dollarValue(cells[$0]) } ?? input
                results[modelId] = ModelPricingRates(
                    input: input,
                    output: output,
                    cacheWrite5m: cacheWrite,
                    cacheWrite1h: cacheWrite,
                    cacheRead: cachedInput
                )
            }
        }

        guard !results.isEmpty else {
            throw PricingFetchError.parseError("No Codex pricing data found")
        }

        return results
    }

    private func columnHeaders(in table: String) -> [String]? {
        let headerArea = elementContents(named: "thead", in: table).first ?? table
        for row in elementContents(named: "tr", in: headerArea).reversed() {
            let headers = elementContents(named: "th", in: row)
                .map { htmlText($0).lowercased() }
            if headers.contains("model"), headers.contains("input"), headers.contains("output") {
                return headers
            }
        }
        return nil
    }

    private func elementContents(named tag: String, in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "<\(tag)\\b[^>]*>(.*?)</\(tag)>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[range])
        }
    }

    private func htmlText(_ html: String) -> String {
        html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#36;", with: "$")
            .replacingOccurrences(of: "&dollar;", with: "$")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func modelId(from text: String) -> String? {
        var candidate = text.lowercased()
        if let qualifier = candidate.firstIndex(of: "(") {
            candidate = String(candidate[..<qualifier])
        }
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.range(of: #"^(?:gpt-[0-9][0-9a-z.\-]*|o[0-9][0-9a-z.\-]*)$"#, options: .regularExpression) != nil else {
            return nil
        }
        return candidate
    }

    private func dollarValue(_ text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned)
    }
}
