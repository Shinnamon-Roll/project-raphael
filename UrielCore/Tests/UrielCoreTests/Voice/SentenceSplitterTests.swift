import Testing
import UrielCore

@Suite("Sentence splitter")
struct SentenceSplitterTests {
  private static let placeholder = SentenceSplitter.codeBlockPlaceholder

  /// Feeds `text` in pieces whose sizes come from `nextSize`, then flushes.
  private func split(_ text: String, sizes nextSize: () -> Int) -> [String] {
    var splitter = SentenceSplitter()
    var sentences: [String] = []
    var rest = Substring(text)
    while !rest.isEmpty {
      let piece = rest.prefix(nextSize())
      rest = rest.dropFirst(piece.count)
      sentences += splitter.append(String(piece))
    }
    return sentences + splitter.flush()
  }

  /// Checks that `text` gives `expected` whether it arrives whole, one character at a time, or in
  /// random pieces cut mid-word and mid-abbreviation.
  private func expectSentences(
    _ text: String, _ expected: [String], sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(split(text) { Int.max } == expected, "whole", sourceLocation: sourceLocation)
    #expect(
      split(text) { 1 } == expected, "one character at a time", sourceLocation: sourceLocation)
    for seed in UInt64(1)...20 {
      var generator = SplitMix64(state: seed)
      let sentences = split(text) { Int.random(in: 1...8, using: &generator) }
      #expect(sentences == expected, "random pieces, seed \(seed)", sourceLocation: sourceLocation)
    }
  }

  @Test(arguments: [
    ("Dr. Smith arrived. He sat down.", ["Dr. Smith arrived.", "He sat down."]),
    ("Use a tool, e.g. a hammer. It works.", ["Use a tool, e.g. a hammer.", "It works."]),
    (
      "He moved to the U.S. last year. He likes it.",
      ["He moved to the U.S. last year.", "He likes it."]
    ),
    ("It costs 3.50 dollars. That is cheap.", ["It costs 3.50 dollars.", "That is cheap."]),
    (
      "Meet at 10:30 a.m. tomorrow. Bring coffee.",
      ["Meet at 10:30 a.m. tomorrow.", "Bring coffee."]
    ),
    ("Wait... really? Yes! Go", ["Wait... really?", "Yes!", "Go"]),
  ])
  func splitsAtSentenceEndsOnly(text: String, expected: [String]) {
    expectSentences(text, expected)
  }

  /// NLTokenizer misreads these; a merge only delays speech, while a wrong split adds a pause.
  @Test(arguments: [
    ("He lives in the U.S. He likes it.", ["He lives in the U.S.", "He likes it."]),
    ("Meet at 10:30 a.m. Bring coffee.", ["Meet at 10:30 a.m.", "Bring coffee."]),
    ("Visit St. Louis today. It is nice.", ["Visit St. Louis today.", "It is nice."]),
  ])
  func tokenizerKnownIssues(text: String, expected: [String]) {
    withKnownIssue("NLTokenizer splits this wrongly") {
      #expect(split(text) { Int.max } == expected)
    }
  }

  @Test func returnsEachSentenceOnceTextFollowsIt() {
    var splitter = SentenceSplitter()
    #expect(splitter.append("I saw Dr.").isEmpty)
    #expect(splitter.append(" Smith today.").isEmpty)
    #expect(splitter.append(" How") == ["I saw Dr. Smith today."])
    #expect(splitter.append(" are you").isEmpty)
    #expect(splitter.flush() == ["How are you"])
  }

  @Test func newlineEndsASentence() {
    var splitter = SentenceSplitter()
    #expect(splitter.append("Here is the list:\n") == ["Here is the list:"])
  }

  @Test(arguments: [
    (
      "**Bold**, *italic*, __strong__, _also_ and ~~gone~~ text.",
      ["Bold, italic, strong, also and gone text."]
    ),
    ("Run `ls -la` now.", ["Run ls -la now."]),
    ("See [the docs](https://example.com/a.b). Then go.", ["See the docs.", "Then go."]),
    ("**Bold one. Bold two.** Plain.", ["Bold one.", "Bold two.", "Plain."]),
    ("Keep snake_case and 5 * 3.", ["Keep snake_case and 5 * 3."]),
    (
      "## Steps\n1. Open Safari.\n2) Go home.\n- Rest a bit\n  * Nested item\n+ Plus item\n> Quoted line.",
      [
        "Steps", "Open Safari.", "Go home.", "Rest a bit", "Nested item", "Plus item",
        "Quoted line.",
      ]
    ),
    ("Mid-line markers stay: 1. - # > here.", ["Mid-line markers stay: 1. - # > here."]),
    ("Above.\n\n---\n\n**\n\n   \nBelow.", ["Above.", "Below."]),
    ("", []),
    ("  \n \n", []),
  ])
  func stripsMarkdown(text: String, expected: [String]) {
    expectSentences(text, expected)
  }

  @Test func replacesACodeBlockWithAPlaceholder() {
    expectSentences(
      "Here is code:\n```swift\nlet x = 1.5\nprint(\"Hi. There\")\n```\nDone.",
      ["Here is code:", Self.placeholder, "Done."])
  }

  @Test func flushDropsAnUnclosedCodeBlockAndResets() {
    var splitter = SentenceSplitter()
    #expect(splitter.append("Try this:\n```\nrm -rf x\nls") == ["Try this:", Self.placeholder])
    #expect(splitter.flush().isEmpty)
    #expect(splitter.append("Next reply. Yes") == ["Next reply."])
    #expect(splitter.flush() == ["Yes"])
  }
}

/// A seeded generator, so a failing random chunking replays the same way.
private struct SplitMix64: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
