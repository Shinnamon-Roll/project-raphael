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

  // MARK: - Thai, which ends a sentence with a space

  private static let thaiParagraph =
    "อรุณสวัสดิ์ค่ะ เมื่อคืนนอนไม่ค่อยหลับเหรอคะ ลองออกไปรับแสงแดดตอนเช้าดู "
    + "จะช่วยให้ตื่นตัวขึ้น แล้วก็ดื่มกาแฟแค่ช่วงเช้าพอนะคะ"
  /// A short clause without a particle runs on into the next one.
  private static let thaiParagraphSentences = [
    "อรุณสวัสดิ์ค่ะ", "เมื่อคืนนอนไม่ค่อยหลับเหรอคะ", "ลองออกไปรับแสงแดดตอนเช้าดู",
    "จะช่วยให้ตื่นตัวขึ้น แล้วก็ดื่มกาแฟแค่ช่วงเช้าพอนะคะ",
  ]

  @Test(arguments: [
    (thaiParagraph, thaiParagraphSentences),
    (
      "ปลาหมึกมีหัวใจสามดวงค่ะ สองดวงแรกสูบเลือดผ่านเหงือก ส่วนดวงที่สามส่งเลือดไปเลี้ยงทั้งตัว",
      ["ปลาหมึกมีหัวใจสามดวงค่ะ", "สองดวงแรกสูบเลือดผ่านเหงือก", "ส่วนดวงที่สามส่งเลือดไปเลี้ยงทั้งตัว"]
    ),
    ("ถ้าอยากได้รสกาแฟชัดๆ แนะนำแฟลตไวท์ค่ะ", ["ถ้าอยากได้รสกาแฟชัดๆ แนะนำแฟลตไวท์ค่ะ"]),
    // The space after ๆ, the repetition mark, is inside a sentence.
    (
      "แฟลตไวท์แก้วเล็กกว่าและมีฟองนมบางๆ เนียนๆ เลยได้รสกาแฟเข้มกว่าค่ะ",
      ["แฟลตไวท์แก้วเล็กกว่าและมีฟองนมบางๆ เนียนๆ เลยได้รสกาแฟเข้มกว่าค่ะ"]
    ),
  ])
  func splitsThaiAtSpacesAfterLongTextOrAParticle(text: String, expected: [String]) {
    expectSentences(text, expected)
  }

  /// Claude's deltas can cut a vowel or tone mark off the letter it belongs to.
  @Test func splitsThaiTheSameWhenDeltasCutLettersApart() {
    var splitter = SentenceSplitter()
    var sentences: [String] = []
    for scalar in Self.thaiParagraph.unicodeScalars { sentences += splitter.append(String(scalar)) }
    #expect(sentences + splitter.flush() == Self.thaiParagraphSentences)
  }

  @Test(arguments: [
    ("ได้ค่ะ เดี๋ยวจัดการให้นะคะ", ["ได้ค่ะ", "เดี๋ยวจัดการให้นะคะ"]),
    // Two spaces, so the random pieces also cut inside the run of whitespace.
    ("ได้ค่ะ  เดี๋ยวจัดการให้นะคะ", ["ได้ค่ะ", "เดี๋ยวจัดการให้นะคะ"]),
    ("ดีใจด้วยนะคะ ลูกแมวสีเทาน่ารักมากเลย", ["ดีใจด้วยนะคะ", "ลูกแมวสีเทาน่ารักมากเลย"]),
    ("ไปก่อนนะ เจอกันพรุ่งนี้", ["ไปก่อนนะ", "เจอกันพรุ่งนี้"]),
    ("ไม่เป็นไรจ้ะ ไว้คุยกันใหม่", ["ไม่เป็นไรจ้ะ", "ไว้คุยกันใหม่"]),
    ("ได้เลยจ้า ไปกันเถอะ", ["ได้เลยจ้า", "ไปกันเถอะ"]),
    // "ชนะ" (to win) ends in "นะ" but is not the particle.
    ("ทีมไทยชนะ เมื่อคืนนี้เอง", ["ทีมไทยชนะ เมื่อคืนนี้เอง"]),
  ])
  func endsAShortThaiSentenceAtAParticle(text: String, expected: [String]) {
    expectSentences(text, expected)
  }

  @Test func returnsAThaiSentenceOnceTheNextLetterArrives() {
    var splitter = SentenceSplitter()
    #expect(splitter.append("ได้ค่ะ").isEmpty)
    #expect(splitter.append(" ").isEmpty)
    #expect(splitter.append("เดี๋ยว") == ["ได้ค่ะ"])
    #expect(splitter.append("ตั้งเวลาให้นะคะ ").isEmpty)
    #expect(splitter.flush() == ["เดี๋ยวตั้งเวลาให้นะคะ"])
  }

  @Test(arguments: [
    (
      "ตั้งเวลา 10 นาทีให้แล้วค่ะ ครบเมื่อไหร่จะบอกนะคะ",
      ["ตั้งเวลา 10 นาทีให้แล้วค่ะ", "ครบเมื่อไหร่จะบอกนะคะ"]
    ),
    ("ตั้งเวลาต้มพาสต้าไว้ให้ทั้งหมด 11 นาทีแล้วค่ะ", ["ตั้งเวลาต้มพาสต้าไว้ให้ทั้งหมด 11 นาทีแล้วค่ะ"]),
    ("ข้างนอกตอนนี้น่าจะร้อนประมาณ 32.5 องศาค่ะ", ["ข้างนอกตอนนี้น่าจะร้อนประมาณ 32.5 องศาค่ะ"]),
  ])
  func keepsNumbersWithTheirUnits(text: String, expected: [String]) {
    expectSentences(text, expected)
  }

  @Test(arguments: [
    ("เปิด Safari ให้แล้วค่ะ", ["เปิด Safari ให้แล้วค่ะ"]),
    ("เปิด System Settings ให้แล้วนะคะ", ["เปิด System Settings ให้แล้วนะคะ"]),
    (
      "เพลงนี้เป็นของวงดนตรีที่ชื่อว่า Coldplay ค่ะ ลองฟังดูนะคะ",
      ["เพลงนี้เป็นของวงดนตรีที่ชื่อว่า Coldplay ค่ะ", "ลองฟังดูนะคะ"]
    ),
  ])
  func keepsEnglishNamesInsideThai(text: String, expected: [String]) {
    expectSentences(text, expected)
  }

  @Test(arguments: [
    (
      "เปิด Notes ให้แล้วค่ะ อยากจดอะไรไว้ไหมคะ? Just say the word.",
      ["เปิด Notes ให้แล้วค่ะ", "อยากจดอะไรไว้ไหมคะ?", "Just say the word."]
    ),
    ("Sure thing. ได้เลยค่ะ ตั้งเวลาให้แล้วนะคะ", ["Sure thing.", "ได้เลยค่ะ", "ตั้งเวลาให้แล้วนะคะ"]),
  ])
  func splitsThaiAndEnglishSentences(text: String, expected: [String]) {
    expectSentences(text, expected)
  }

  @Test(arguments: [
    (
      "## วิธีทำ\n1. ต้มเส้นสปาเก็ตตี้ค่ะ\n- ใส่ **กระเทียม** กับผักโขมนะคะ",
      ["วิธีทำ", "ต้มเส้นสปาเก็ตตี้ค่ะ", "ใส่ กระเทียม กับผักโขมนะคะ"]
    ),
    ("**ได้ค่ะ วันนี้อากาศดีมากเลย**", ["ได้ค่ะ", "วันนี้อากาศดีมากเลย"]),
  ])
  func stripsMarkdownFromThai(text: String, expected: [String]) {
    expectSentences(text, expected)
  }

  @Test func flushReturnsTheRestOfAThaiReplyAndResets() {
    var splitter = SentenceSplitter()
    #expect(splitter.append("ขอบคุณค่ะ ").isEmpty)
    #expect(splitter.flush() == ["ขอบคุณค่ะ"])
    #expect(splitter.append("ฝันดีนะคะ").isEmpty)
    #expect(splitter.flush() == ["ฝันดีนะคะ"])
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
