import Foundation

/// Synthetic sessions made with `say`, so the whole pipeline runs before the owner records
/// anything. Never the owner's voice; these files are git-ignored too.
enum Synth {
  /// Thai lines with no wake phrase, said by Kanya between the calls.
  static let fillers = [
    "วันนี้อากาศร้อนมากเลย ต้องเปิดแอร์ทั้งวัน",
    "เมื่อวานไปกินข้าวมันไก่ที่ร้านใกล้บ้านมา อร่อยดี",
    "ตอนเย็นว่าจะออกไปวิ่งที่สวนสาธารณะสักหน่อย",
    "งานที่ออฟฟิศช่วงนี้เยอะมาก แต่ก็สนุกดี",
    "สุดสัปดาห์นี้อยากไปเที่ยวทะเลกับเพื่อน",
    "กาแฟแก้วนี้หวานไปหน่อย คราวหน้าขอหวานน้อย",
  ]

  /// Thai talk with the near-words, for the synthetic background: none of it is a call.
  static let nearWordTalk = [
    "ช่วงนี้ปุ๋ยยูเรียราคาขึ้นเยอะเลยนะ",
    "คุณยูริเพิ่งย้ายมาทำงานที่บริษัทเราเมื่อเดือนที่แล้ว",
    "น้องชายกำลังเรียนพิเศษภาษาอังกฤษอยู่",
    "ยูเรียเป็นปุ๋ยไนโตรเจนที่ชาวนาใช้กันมาก",
    "การ์ตูนเรื่องนี้ตัวเอกชื่อยูริ น่ารักมาก",
    "ใส่ยูเรียนิดเดียวก็พอ ไม่ต้องเยอะ",
    "พรุ่งนี้มีเรียนตอนเช้า ต้องตื่นเร็ว",
    "ยูเรียนี่ใช้กับนาข้าวได้ไหม",
    "ซื้อยูเรียหนึ่งกระสอบมาไว้ที่บ้าน",
  ]

  struct Speaker {
    var voice: String
    var setting: String
    /// What the voice says for each phrase.
    var text: [Phrase: String]
    /// Whether the Thai request is part of the same `say` call, as one Thai sentence.
    var saysRequest: Bool
  }

  static let speakers = [
    Speaker(
      voice: "Kanya", setting: "synthetic-kanya",
      text: [.uriel: "ยูเรียล", .heyUriel: "เฮ้ ยูเรียล"], saysRequest: true),
    Speaker(
      voice: "Samantha", setting: "synthetic-samantha",
      text: [.uriel: "Uriel", .heyUriel: "Hey Uriel"], saysRequest: false),
  ]

  /// Calls per synthetic session.
  static let calls = 6

  /// Writes the sessions to `audio/synthetic/` and returns their paths.
  static func run() throws -> [URL] {
    let scratch = FileManager.default.temporaryDirectory.appending(
      path: "wakeword-synth-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let say = Say(folder: scratch)
    var written: [URL] = []
    for speaker in speakers {
      for phrase in Phrase.allCases {
        var session = Session()
        for index in 0..<calls {
          session.append(try say("Kanya", fillers[index % fillers.count]))
          session.silence(1.5)
          // The cue comes a second before the phrase, about as long as the owner takes to react.
          let request = Recorder.requests[index % Recorder.requests.count]
          session.cue(at: session.duration - 1, text: "\(phrase.spoken) … \(request)")
          if speaker.saysRequest {
            session.append(try say(speaker.voice, "\(speaker.text[phrase]!) \(request)"))
          } else {
            session.append(try say(speaker.voice, speaker.text[phrase]!))
            session.silence(0.15)
            session.append(try say("Kanya", request))
          }
          session.silence(2.5)
        }
        let url = SpikePaths.synthetic.appending(
          path: "calls-\(phrase.rawValue)-\(speaker.setting).wav")
        try session.write(to: url, label: .calls, phrase: phrase, setting: speaker.setting)
        written.append(url)
      }
    }
    var background = Session()
    for line in nearWordTalk + fillers {
      background.append(try say("Kanya", line))
      background.silence(1)
    }
    let url = SpikePaths.synthetic.appending(path: "background-synthetic-talk.wav")
    try background.write(to: url, label: .background, phrase: nil, setting: "synthetic-talk")
    written.append(url)
    return written
  }

  /// Audio built up piece by piece, with its cues.
  struct Session {
    var samples: [Float] = []
    var cues: [Cue] = []

    var duration: Double { Double(samples.count) / SpikeAudio.sampleRate }

    mutating func append(_ more: [Float]) { samples += more }

    mutating func silence(_ seconds: Double) {
      samples += Array(repeating: 0, count: Int(seconds * SpikeAudio.sampleRate))
    }

    mutating func cue(at time: Double, text: String) { cues.append(Cue(time: time, text: text)) }

    func write(to url: URL, label kind: SessionLabel.Kind, phrase: Phrase?, setting: String) throws
    {
      try WAVWriter.write(samples, to: url)
      try SessionLabel(
        kind: kind, phrase: phrase, setting: setting, recorded: .now, duration: duration,
        window: SessionLabel.defaultWindow, cues: cues
      ).write(for: url)
    }
  }

  /// Runs `/usr/bin/say` into a 16 kHz 16-bit WAV and reads it back.
  struct Say {
    var folder: URL

    func callAsFunction(_ voice: String, _ text: String) throws -> [Float] {
      let url = folder.appending(path: "\(UUID().uuidString).wav")
      let process = Process()
      process.executableURL = URL(filePath: "/usr/bin/say")
      process.arguments = [
        "-v", voice, "-o", url.path(percentEncoded: false), "--data-format=LEI16@16000", text,
      ]
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw SpikeError("`say -v \(voice)` failed (exit \(process.terminationStatus)).")
      }
      return try SpikeAudio.read(url)
    }
  }
}
