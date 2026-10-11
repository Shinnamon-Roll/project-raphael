import Foundation
import NaturalLanguage

/// Splits Claude's streamed reply into sentences for the voice, which starts on the first sentence
/// and speaks one `AVSpeechUtterance` per sentence.
///
/// Feed each text delta to ``append(_:)`` and call ``flush()`` when the reply ends. Each sentence
/// comes back as plain speech, with markdown removed, and is never empty.
public struct SentenceSplitter: Sendable {
  /// Spoken once in place of each fenced code block, which makes no sense read aloud.
  public static let codeBlockPlaceholder = "I've skipped a code block."

  /// Received text not yet returned: the unfinished end of the current line.
  private var pending = ""
  /// Whether the next sentence begins a line, where list, quote and heading markers can appear.
  private var atLineStart = true
  private var inCodeBlock = false

  public init() {}

  /// Adds a text delta and returns the sentences it completed, in order.
  ///
  /// A sentence is complete only once text follows it, because until then the tokenizer may still
  /// extend it, as with "Dr." before "Smith".
  public mutating func append(_ delta: String) -> [String] {
    pending += delta
    return drain(isEnd: false)
  }

  /// Ends the reply: returns what is left, even without final punctuation, and resets the splitter
  /// for the next reply.
  public mutating func flush() -> [String] {
    let sentences = drain(isEnd: true)
    self = Self()
    return sentences
  }

  private mutating func drain(isEnd: Bool) -> [String] {
    var spoken: [String] = []
    // A newline always ends a sentence, so each complete line is split on its own.
    while let newline = pending.firstIndex(of: "\n") {
      let line = String(pending[..<newline])
      pending.removeSubrange(...newline)
      for range in Self.sentenceRanges(in: line) { speak(line[range], into: &spoken) }
      atLineStart = true
    }
    var ranges = Self.sentenceRanges(in: pending)
    let unfinished = isEnd ? nil : ranges.popLast()
    for range in ranges { speak(pending[range], into: &spoken) }
    if isEnd {
      pending = ""
    } else if let unfinished {
      pending = String(pending[unfinished.lowerBound...])
    }
    return spoken
  }

  /// Adds one sentence of the reply to `spoken` as plain speech, unless nothing in it is speakable.
  private mutating func speak(_ sentence: Substring, into spoken: inout [String]) {
    defer { atLineStart = false }
    if atLineStart, sentence.drop(while: \.isWhitespace).hasPrefix("```") {
      // shortcut: only backtick fences; add "~~~" fences if Claude ever sends them.
      inCodeBlock.toggle()
      if inCodeBlock { spoken.append(Self.codeBlockPlaceholder) }
    } else if !inCodeBlock, let text = Self.plainSpeech(sentence, atLineStart: atLineStart) {
      spoken.append(text)
    }
  }

  private static func sentenceRanges(in text: String) -> [Range<String.Index>] {
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = text
    // Uriel speaks English only, and a fixed language keeps short fragments from being misread.
    tokenizer.setLanguage(.english)
    return tokenizer.tokens(for: text.startIndex..<text.endIndex)
  }

  /// The sentence without markdown and with its whitespace collapsed, or nil when no letter or
  /// digit is left, as with a lone list number or a horizontal rule.
  private static func plainSpeech(_ sentence: Substring, atLineStart: Bool) -> String? {
    func replacing(_ pattern: NSRegularExpression, in text: String, with template: String)
      -> String
    {
      pattern.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
    var text = String(sentence)
    if atLineStart { text = replacing(lineMarker, in: text, with: "") }
    for (pattern, template) in inlineMarkup { text = replacing(pattern, in: text, with: template) }
    text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return text.contains { $0.isLetter || $0.isNumber } ? text : nil
  }

  /// Quote, heading and list markers at the start of a line: "> ", "## ", "- ", "1. ".
  private static let lineMarker = regex(
    #"^[ \t]*(?:>[ \t]*)*(?:(?:#{1,6}|[-*+]|\d{1,9}[.)])[ \t]+)?"#)

  /// Inline markup and the template that replaces it, applied in order.
  private static let inlineMarkup: [(NSRegularExpression, String)] = [
    // A link keeps only its text: "[text](url)" becomes "text".
    // shortcut: a sentence end inside link text splits the link first, so its brackets and URL
    // are spoken; and "2*3" loses its "*". Fix if real replies show either.
    (regex(#"\[([^\]]*)\]\([^)]*\)"#), "$1"),
    // Code spans and strikethrough lose their markers and keep their text.
    (regex("`+|~~"), ""),
    // A run of asterisks is emphasis unless it stands between spaces, like a times sign.
    (regex(#"(?<![\s*])\*+|\*+(?![\s*])"#), ""),
    // A run of underscores is emphasis unless it is inside a word, as in "snake_case".
    (regex(#"(?<![\p{L}\p{N}_])_+|_+(?![\p{L}\p{N}_])"#), ""),
  ]

  private static func regex(_ pattern: String) -> NSRegularExpression {
    // The patterns are constants, so the tests catch a bad one.
    try! NSRegularExpression(pattern: pattern)
  }
}
