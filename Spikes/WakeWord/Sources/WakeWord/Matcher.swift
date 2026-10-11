import Foundation

/// Finds the wake phrase in a Thai transcript.
///
/// `DictationTranscriber` (th-TH) writes Thai words with no spaces between them and puts spaces
/// around Latin words. Thai pronounces a final ล as n, so a Thai voice saying "ยูเรียล" comes back
/// as "ยูเรียน" (checked with Kanya on 2026-10-12). The near-word "ยูเรีย" (urea) differs from the
/// wake word by its last letter only, so Thai spellings match exactly instead of by edit distance.
enum WakePhraseMatcher {
  /// Thai spellings of "Uriel", tone marks removed, also with ล for ร as many Thai speakers say it
  /// ("ยูเลี่ยน" came back from Kanya). Extend this list from what replay prints under "What the
  /// engine heard".
  static let thaiSpellings = [
    "ยูเรียน", "ยูเรียล", "ยูเลียน", "ยูเลียล", "ยูเรล", "ยูเรน", "อูเรียน", "อูเรียล", "ยูริเอล",
  ]

  /// The Latin word, matched with at most one edit: "Uriel", "Urial", "Ariel".
  static let latinWord = "uriel"

  /// Thai and Latin spellings of "hey" that may come right before the name, tone marks removed.
  /// Kanya's "เฮ้" comes back as "เค" or "เคย์".
  static let heySpellings = ["เฮ", "เฮย", "เอ", "เค", "เคย", "hey", "hay", "hi", "he"]

  /// What `AnalysisContext.contextualStrings` gets when the context is on.
  static let contextualStrings = ["Uriel", "Hey Uriel", "ยูเรียล", "เฮ้ยูเรียล"]

  /// One match of the phrase in a transcript.
  struct Match: Equatable, Sendable {
    /// The phrase as it appears in the normalized transcript, such as `ยูเรียน` or `hey uriel`.
    var heard: String
    var phrase: Phrase
  }

  /// Every occurrence of `phrase` in `text`, in order.
  ///
  /// "Uriel" matches every name, with or without "hey"; "Hey Uriel" only a name right after a
  /// spelling of "hey".
  static func matches(of phrase: Phrase, in text: String) -> [Match] {
    let scalars = Array(normalize(text).unicodeScalars)
    return names(in: scalars).compactMap { name in
      guard phrase == .heyUriel else { return Match(heard: string(scalars[name]), phrase: .uriel) }
      guard let hey = hey(before: name.lowerBound, in: scalars) else { return nil }
      return Match(heard: string(scalars[hey..<name.upperBound]), phrase: .heyUriel)
    }
  }

  /// Lowercase, Thai tone marks and the silent-letter mark removed, punctuation turned into spaces,
  /// runs of spaces collapsed.
  static func normalize(_ text: String) -> String {
    var scalars = String.UnicodeScalarView()
    var lastWasSpace = true
    for scalar in text.lowercased().unicodeScalars {
      if (0x0E48...0x0E4C).contains(scalar.value) { continue }  // ่ ้ ๊ ๋ ์
      let isSpace =
        CharacterSet.whitespacesAndNewlines.contains(scalar)
        || CharacterSet.punctuationCharacters.contains(scalar)
        || CharacterSet.symbols.contains(scalar)
      if isSpace {
        if !lastWasSpace { scalars.append(" ") }
        lastWasSpace = true
      } else {
        scalars.append(scalar)
        lastWasSpace = false
      }
    }
    if scalars.last == " " { scalars.removeLast() }
    return String(scalars)
  }

  /// The ranges of the name in normalized text, in order, never overlapping.
  static func names(in text: [Unicode.Scalar]) -> [Range<Int>] {
    var found: [Range<Int>] = []
    for spelling in thaiSpellings {
      found += occurrences(of: Array(spelling.unicodeScalars), in: text)
        .filter { !startsNextSyllable(at: $0.upperBound, in: text) }
    }
    found += latinWords(in: text).filter { editDistance(text[$0], latinWord.unicodeScalars) <= 1 }
    var kept: [Range<Int>] = []
    for range in found.sorted(by: { ($0.lowerBound, -$0.count) < ($1.lowerBound, -$1.count) })
    where !kept.contains(where: { $0.overlaps(range) }) {
      kept.append(range)
    }
    return kept
  }

  /// Whether the Thai letter before `index` begins a new syllable rather than ending this one: a
  /// dependent vowel right after it, as in "ยูเรียนะ" (urea + นะ) or "ยูเรียนี้".
  ///
  /// shortcut: a final consonant followed by a new consonant ("ยูเรียนก", urea + น…) still matches;
  /// upgrade to a Thai word segmenter if the owner's talk background shows such false triggers.
  static func startsNextSyllable(at index: Int, in text: [Unicode.Scalar]) -> Bool {
    guard text.indices.contains(index) else { return false }
    let next = text[index].value
    return (0x0E30...0x0E3A).contains(next) || next == 0x0E45 || next == 0x0E47
  }

  /// The start of a "hey" right before `index`, with or without a space between.
  static func hey(before index: Int, in text: [Unicode.Scalar]) -> Int? {
    let end = index > 0 && text[index - 1] == " " ? index - 1 : index
    for spelling in heySpellings.map({ Array($0.unicodeScalars) }).sorted(by: {
      $0.count > $1.count
    }) {
      let start = end - spelling.count
      guard start >= 0, Array(text[start..<end]) == spelling else { continue }
      // A Latin "hey" must be its own word, not the end of "they".
      if spelling[0].isASCII, start > 0, isLatinLetter(text[start - 1]) { continue }
      return start
    }
    return nil
  }

  /// Maximal runs of ASCII letters.
  static func latinWords(in text: [Unicode.Scalar]) -> [Range<Int>] {
    var words: [Range<Int>] = []
    var start: Int?
    for (index, scalar) in text.enumerated() {
      if isLatinLetter(scalar) {
        if start == nil { start = index }
      } else if let begin = start {
        words.append(begin..<index)
        start = nil
      }
    }
    if let start { words.append(start..<text.count) }
    return words
  }

  /// Levenshtein distance between two scalar sequences.
  static func editDistance(
    _ lhs: some Collection<Unicode.Scalar>, _ rhs: some Collection<Unicode.Scalar>
  ) -> Int {
    let a = Array(lhs)
    let b = Array(rhs)
    guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
    var previous = Array(0...b.count)
    for i in 1...a.count {
      var current = [i] + Array(repeating: 0, count: b.count)
      for j in 1...b.count {
        current[j] = min(
          previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
      }
      previous = current
    }
    return previous[b.count]
  }

  private static func occurrences(of pattern: [Unicode.Scalar], in text: [Unicode.Scalar])
    -> [Range<Int>]
  {
    guard !pattern.isEmpty, text.count >= pattern.count else { return [] }
    return (0...(text.count - pattern.count)).filter { start in
      text[start..<(start + pattern.count)].elementsEqual(pattern)
    }.map { $0..<($0 + pattern.count) }
  }

  private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
    ("a"..."z").contains(scalar)
  }

  private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
    String(String.UnicodeScalarView(scalars))
  }
}
