import UrielCore

/// Token counts of one response, in the results files.
struct TokenCounts: Codable, Sendable, Hashable {
  var input = 0
  var output = 0
  var cacheWrite = 0
  var cacheRead = 0
}

extension TokenCounts {
  init(_ usage: Usage) {
    self.init(
      input: usage.inputTokens, output: usage.outputTokens,
      cacheWrite: usage.cacheCreationInputTokens, cacheRead: usage.cacheReadInputTokens)
  }
}

/// Dollars per million tokens (CLAUDE.md, Platform facts › Claude API; the pricing page wins).
struct Prices: Sendable, Hashable {
  let input: Double
  let output: Double
  /// The 5-minute TTL, which is all the spike uses: 1.25× input.
  let cacheWrite: Double
  let cacheRead: Double

  /// shortcut: Haiku 5.5's price is for prompts up to 100K tokens; the spike's are about 1K.
  static func of(_ model: String) -> Prices? {
    switch model {
    case Configuration.haiku: Prices(input: 0.10, output: 0.50, cacheWrite: 0.125, cacheRead: 0.01)
    case Configuration.sonnet: Prices(input: 2, output: 10, cacheWrite: 2.50, cacheRead: 0.10)
    default: nil
    }
  }

  func cost(of tokens: TokenCounts) -> Double {
    (Double(tokens.input) * input + Double(tokens.output) * output
      + Double(tokens.cacheWrite) * cacheWrite + Double(tokens.cacheRead) * cacheRead) / 1_000_000
  }

  /// The most one request can cost: every input token at the cache-write price, the dearest input
  /// price, and the whole `maxTokens` of output, thinking included.
  ///
  /// A token is at least one byte of the body, plus an allowance for the tool-use system prompt
  /// the API adds. shortcut: the allowance is a guess; raise it if a request's input passes it.
  func worstCase(bodyBytes: Int, maxTokens: Int) -> Double {
    (Double(bodyBytes + 1_000) * cacheWrite + Double(maxTokens) * output) / 1_000_000
  }
}

/// A hard cap on what a run spends, kept from each response's usage.
struct Budget: Sendable {
  let cap: Double
  private(set) var spent = 0.0

  init(cap: Double) {
    self.cap = cap
  }

  /// Whether a request that costs at most `worstCase` cannot pass the cap.
  func allows(_ worstCase: Double) -> Bool { spent + worstCase <= cap }

  mutating func add(_ cost: Double) { spent += cost }
}

/// The `p`th percentile (0–100) of `values`, interpolating between the closest ranks, the way
/// numpy's default does; `nil` when there are none.
func percentile(_ p: Double, of values: [Double]) -> Double? {
  guard !values.isEmpty else { return nil }
  let sorted = values.sorted()
  let rank = p / 100 * Double(sorted.count - 1)
  let lower = Int(rank.rounded(.down))
  let upper = min(lower + 1, sorted.count - 1)
  return sorted[lower] + (sorted[upper] - sorted[lower]) * (rank - Double(lower))
}

extension Duration {
  var seconds: Double { self / .seconds(1) }
}
