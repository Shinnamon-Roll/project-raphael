import Testing
import UrielCore

@testable import Latency

@Suite("Percentiles, cost and the budget cap")
struct CostTests {
  @Test func percentileInterpolatesBetweenRanks() {
    #expect(percentile(50, of: [4, 1, 3, 2]) == 2.5)
    #expect(percentile(0, of: [4, 1, 3, 2]) == 1)
    #expect(percentile(100, of: [4, 1, 3, 2]) == 4)
    let hundred = (1...100).map(Double.init)
    #expect(abs((percentile(95, of: hundred) ?? 0) - 95.05) < 1e-9)
    #expect(percentile(95, of: [7]) == 7)
    #expect(percentile(50, of: []) == nil)
  }

  @Test func costUsesEachTokenKindsPrice() throws {
    let tokens = TokenCounts(input: 100, output: 200, cacheWrite: 1_000, cacheRead: 2_000)
    let sonnet = try #require(Prices.of(Configuration.sonnet))
    // 100 × 2 + 200 × 10 + 1000 × 2.5 + 2000 × 0.1 = 4900 per million.
    #expect(abs(sonnet.cost(of: tokens) - 0.0049) < 1e-12)
    let haiku = try #require(Prices.of(Configuration.haiku))
    // 100 × 0.1 + 200 × 0.5 + 1000 × 0.125 + 2000 × 0.01 = 255 per million.
    #expect(abs(haiku.cost(of: tokens) - 0.000255) < 1e-12)
    #expect(Prices.of("claude-unknown") == nil)
  }

  @Test func tokenCountsComeFromUsage() {
    let usage = Usage(
      inputTokens: 1, outputTokens: 2, cacheCreationInputTokens: 3, cacheReadInputTokens: 4)
    #expect(TokenCounts(usage) == TokenCounts(input: 1, output: 2, cacheWrite: 3, cacheRead: 4))
  }

  @Test func worstCaseIsAboveAnyRealCostOfTheSameRequest() throws {
    let sonnet = try #require(Prices.of(Configuration.sonnet))
    // (5000 + 1000) × 2.5 + 2048 × 10 per million.
    #expect(abs(sonnet.worstCase(bodyBytes: 5_000, maxTokens: 2_048) - 0.03548) < 1e-12)
    let real = TokenCounts(input: 1_000, output: 2_048, cacheWrite: 0, cacheRead: 5_000)
    #expect(sonnet.cost(of: real) < sonnet.worstCase(bodyBytes: 5_000, maxTokens: 2_048))
  }

  @Test func budgetStopsBeforeARequestThatCouldPassTheCap() {
    var budget = Budget(cap: 1.00)
    budget.add(0.95)
    #expect(budget.allows(0.05))
    #expect(!budget.allows(0.0501))
    budget.add(0.05)
    #expect(!budget.allows(0.0001))
    #expect(budget.allows(0))
  }
}
