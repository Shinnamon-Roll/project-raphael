import Testing

@testable import WakeWord

@Suite("The wake-phrase matcher on Thai and Latin transcripts")
struct MatcherTests {
  private func heard(_ phrase: Phrase, _ text: String) -> [String] {
    WakePhraseMatcher.matches(of: phrase, in: text).map(\.heard)
  }

  @Test(arguments: [
    // What DictationTranscriber wrote for Kanya's "ยูเรียล", with and without contextual strings.
    "สวัสดีค่ะวันนี้อากาศดีมากยูเรียนเปิด Safari ให้หน่อย",
    "ยูเรียลตั้งเวลา 5 นาทีหน่อย",
    // ล for ร, and a tone mark the matcher drops.
    "สักหน่อยยูเลี่ยนวันนี้อากาศเป็นยังไง",
    "อูเรียล เปิดเพลงให้หน่อย",
    "Uriel, open Safari",
    "ok urial what time is it",
  ])
  func findsTheName(in text: String) {
    #expect(heard(.uriel, text).count == 1)
  }

  @Test(arguments: [
    // The near-words: urea, alone or running into the next syllable, and Yuri.
    "ช่วงนี้ปุ๋ยยูเรียราคาขึ้นเยอะเลยนะ",
    "ใส่ยูเรียนิดเดียวก็พอ",
    "ยูเรียนี่ใช้กับนาข้าวได้ไหม",
    "ซื้อยูเรียนะ",
    "คุณยูริเพิ่งย้ายมาทำงาน",
    "ยูรีเล่าเรื่องตลกให้ฟังหน่อย",
    "น้องชายกำลังเรียนพิเศษภาษาอังกฤษอยู่",
    "the urea price",
    "",
  ])
  func ignoresNearWords(in text: String) {
    #expect(heard(.uriel, text).isEmpty)
    #expect(heard(.heyUriel, text).isEmpty)
  }

  @Test func heyUrielNeedsAHeyRightBeforeTheName() {
    #expect(heard(.heyUriel, "เพื่อนเฮย์ยูเรียนตั้งเวลา 10 นาทีนะ") == ["เฮยยูเรียน"])
    #expect(heard(.heyUriel, "เคยูเรียนตั้งเวลา 5 นาทีหน่อย") == ["เคยูเรียน"])
    #expect(heard(.heyUriel, "เฮ้ ยูเรียล ตั้งเวลา") == ["เฮ ยูเรียล"])
    #expect(heard(.heyUriel, "Hey Uriel, what's up") == ["hey uriel"])
    #expect(heard(.heyUriel, "ยูเรียนเปิด Safari").isEmpty)
    // A Latin "he" inside "the" is not a hey.
    #expect(heard(.heyUriel, "the uriel").isEmpty)
    // "Uriel" also matches the name inside "Hey Uriel".
    #expect(heard(.uriel, "Hey Uriel") == ["uriel"])
  }

  @Test func countsEveryOccurrenceInOrder() {
    let text = "ยูเรียนเปิดเพลงแล้วก็ยูเรียลตั้งเวลา Uriel"
    #expect(heard(.uriel, text) == ["ยูเรียน", "ยูเรียล", "uriel"])
  }

  @Test func normalizesCaseTonesAndPunctuation() {
    #expect(WakePhraseMatcher.normalize("  Hey,  URIEL!! เฮ้ ") == "hey uriel เฮ")
    #expect(WakePhraseMatcher.normalize("ยูเลี่ยน") == "ยูเลียน")
  }

  @Test func editDistanceCountsSingleEdits() {
    #expect(WakePhraseMatcher.editDistance("uriel".unicodeScalars, "uriel".unicodeScalars) == 0)
    #expect(WakePhraseMatcher.editDistance("urial".unicodeScalars, "uriel".unicodeScalars) == 1)
    #expect(WakePhraseMatcher.editDistance("urea".unicodeScalars, "uriel".unicodeScalars) == 2)
    #expect(WakePhraseMatcher.editDistance("".unicodeScalars, "uriel".unicodeScalars) == 5)
  }
}

@Suite("Turning transcriber results into detections")
struct TrackerTests {
  @Test func aGrowingVolatileResultReportsTheNameOnce() {
    var tracker = TranscriptTracker()
    #expect(tracker.detections(in: "สวัสดีค่ะยู", start: 0, end: 3.7).isEmpty)
    let first = tracker.detections(in: "สวัสดีค่ะยูเรียน", start: 0, end: 3.96)
    #expect(first == [Detection(phrase: .uriel, time: 3.96, heard: "ยูเรียน")])
    #expect(tracker.detections(in: "สวัสดีค่ะยูเรียนเปิด", start: 0, end: 5.3).isEmpty)
    #expect(tracker.detections(in: "สวัสดีค่ะยูเรียนเปิด Safari", start: 0, end: 5.9).isEmpty)
  }

  @Test func aFinalResultThatCutsTheStretchDoesNotCountTheNameAgain() {
    var tracker = TranscriptTracker()
    _ = tracker.detections(in: "ยูเรียนเปิดเพลง", start: 40, end: 51)
    // The final splits off a stretch that starts before the detection; the next volatile result
    // starts after the name but before its detection time.
    #expect(tracker.detections(in: "ยูเรียนเปิด", start: 44, end: 50.5).isEmpty)
    #expect(tracker.detections(in: "ยูเรียนเปิดเพลงกาแฟ", start: 46.6, end: 67.9).isEmpty)
  }

  @Test func aSecondCallInTheSameStretchIsNew() {
    var tracker = TranscriptTracker()
    _ = tracker.detections(in: "ยูเรียนเปิดเพลง", start: 0, end: 6)
    let second = tracker.detections(in: "ยูเรียนเปิดเพลงแล้วก็ยูเรียลตั้งเวลา", start: 0, end: 17)
    #expect(second == [Detection(phrase: .uriel, time: 17, heard: "ยูเรียล")])
  }

  @Test func heyUrielAlsoCountsAsUriel() {
    var tracker = TranscriptTracker()
    let found = tracker.detections(in: "เฮ้ยูเรียนตั้งเวลา", start: 0, end: 2)
    #expect(found.map(\.phrase) == [.uriel, .heyUriel])
  }
}
