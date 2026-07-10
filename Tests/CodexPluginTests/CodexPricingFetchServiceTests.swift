import XCTest
import ClaudeStatisticsKit

final class CodexPricingFetchServiceTests: XCTestCase {
    func testParsesCacheWriteColumnWithoutTreatingItAsOutput() throws {
        let html = table(headers: ["Model", "Input", "Cached input", "Cache writes", "Output"], rows: [
            ["gpt-5.6-sol", "$5.00", "$0.50", "$6.25", "$30.00"],
            ["gpt-5.5-pro", "$30.00", "-", "-", "$180.00"],
        ])

        let pricing = try CodexPricingFetchService.shared.parsePricingFromHTML(html)

        XCTAssertEqual(pricing["gpt-5.6-sol"]?.input, 5)
        XCTAssertEqual(pricing["gpt-5.6-sol"]?.cacheRead, 0.5)
        XCTAssertEqual(pricing["gpt-5.6-sol"]?.cacheWrite5m, 6.25)
        XCTAssertEqual(pricing["gpt-5.6-sol"]?.output, 30)
        XCTAssertEqual(pricing["gpt-5.5-pro"]?.cacheRead, 0)
        XCTAssertEqual(pricing["gpt-5.5-pro"]?.cacheWrite5m, 30)
        XCTAssertEqual(pricing["gpt-5.5-pro"]?.output, 180)
    }

    func testParsesLegacyThreePriceColumns() throws {
        let html = table(headers: ["Model", "Input", "Cached input", "Output"], rows: [
            ["gpt-5.3-codex", "$1.75", "$0.175", "$14.00"],
        ])

        let pricing = try CodexPricingFetchService.shared.parsePricingFromHTML(html)

        XCTAssertEqual(pricing["gpt-5.3-codex"]?.input, 1.75)
        XCTAssertEqual(pricing["gpt-5.3-codex"]?.cacheWrite1h, 1.75)
        XCTAssertEqual(pricing["gpt-5.3-codex"]?.output, 14)
    }

    func testUsesShortContextColumnsAndKeepsFirstStandardTable() throws {
        let headers = [
            "Model", "Input", "Cached input", "Cache writes", "Output",
            "Input", "Cached input", "Cache writes", "Output",
        ]
        let standard = table(headers: headers, rows: [
            ["gpt-5.6-terra", "$2.50", "$0.25", "$3.125", "$15.00", "$5.00", "$0.50", "$6.25", "$22.50"],
        ])
        let batch = table(headers: headers, rows: [
            ["gpt-5.6-terra", "$1.25", "$0.125", "$1.5625", "$7.50", "$2.50", "$0.25", "$3.125", "$11.25"],
        ])

        let pricing = try CodexPricingFetchService.shared.parsePricingFromHTML(standard + batch)

        XCTAssertEqual(pricing["gpt-5.6-terra"]?.input, 2.5)
        XCTAssertEqual(pricing["gpt-5.6-terra"]?.output, 15)
    }

    private func table(headers: [String], rows: [[String]]) -> String {
        let headerHTML = headers.map { "<th><span>\($0)</span></th>" }.joined()
        let rowHTML = rows.map { cells in
            "<tr>" + cells.map { "<td><span>\($0)</span></td>" }.joined() + "</tr>"
        }.joined()
        return "<table><thead><tr>\(headerHTML)</tr></thead><tbody>\(rowHTML)</tbody></table>"
    }
}
