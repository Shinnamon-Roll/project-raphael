import Foundation
import NaturalLanguage

/// Splits Claude's streamed reply into sentences for the voice, which starts on the first sentence
/// and speaks one `AVSpeechUtterance` per sentence.
///
/// Feed each text delta to ``append(_:)`` and call ``flush()`` when the reply ends. Each sentence
/// comes back as plain speech, with markdown removed, and is never empty. Thai, which ends a
/// sentence with a space rather than a full stop, is split at those spaces too.
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
    // A fixed language keeps short fragments from being misread. No language makes the tokenizer
    // split Thai, so Thai is split below.
    tokenizer.setLanguage(.english)
    return tokenizer.tokens(for: text.startIndex..<text.endIndex).flatMap {
      thaiSentenceRanges(in: $0, of: text)
    }
  }

  /// Splits one tokenizer sentence at the spaces that end Thai sentences. A run of whitespace ends
  /// one when it stands between two Thai letters and the text since the last end is long enough to
  /// sound natural alone, or ends in a sentence-final particle. Next to a digit or a Latin letter,
  /// as in "ตั้งเวลา 10 นาที" or "เปิด Safari ให้แล้วค่ะ", it never does.
  ///
  /// A space is an end only once the letter after it has arrived; until then the last range runs
  /// to the end of `range`, and the splitter holds the last range back.
  /// shortcut: Thai followed by Latin with no punctuation stays one sentence ("ได้ค่ะ Hello there.");
  /// split after a particle there too if real replies show it.
  private static func thaiSentenceRanges(
    in range: Range<String.Index>, of text: String
  ) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var start = range.lowerBound
    var searchStart = range.lowerBound
    while let space = text[searchStart..<range.upperBound].firstIndex(where: \.isWhitespace) {
      let next = text[space..<range.upperBound].firstIndex { !$0.isWhitespace } ?? range.upperBound
      searchStart = next
      let before = space > start ? text[text.index(before: space)] : " "
      // Thai writes a space after ๆ, the repetition mark, inside a sentence too: "จริงๆ ว่า".
      guard next < range.upperBound, isThai(before), before != "ๆ", isThai(text[next]) else {
        continue
      }
      let sentence = text[start..<space]
      if sentence.count >= minimumThaiSentence || endsInParticle(sentence) {
        ranges.append(start..<next)
        start = next
      }
    }
    ranges.append(start..<range.upperBound)
    return ranges
  }

  /// The shortest Thai text, in characters, that a space ends without a particle.
  /// shortcut: 20 characters, about eight syllables or a second and a half of speech; tune it by
  /// ear once Uriel speaks real Thai replies.
  private static let minimumThaiSentence = 20

  /// Polite and friendly particles that end a Thai sentence; "นะคะ" and "นะครับ" end in one too.
  private static let thaiParticles: Set<String> = ["ค่ะ", "คะ", "ครับ", "นะ", "จ้ะ", "จ้า"]

  /// A Thai letter, vowel or mark. Thai digits count as digits, like "10".
  private static func isThai(_ character: Character) -> Bool {
    !character.isNumber
      && character.unicodeScalars.first.map { (0x0E00...0x0E7F).contains($0.value) } == true
  }

  /// Whether `text` ends in a particle that is a word of its own: "ไปก่อนนะ" does, while "ชนะ"
  /// (to win) does not.
  private static func endsInParticle(_ text: Substring) -> Bool {
    guard thaiParticles.contains(where: { text.hasSuffix($0) }) else { return false }
    let string = String(text)
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = string
    tokenizer.setLanguage(.thai)
    let last = tokenizer.tokens(for: string.startIndex..<string.endIndex).last
    return last.map { thaiParticles.contains(String(string[$0])) } ?? false
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
