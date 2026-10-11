import Foundation
import Speech
import Testing

@testable import WakeWord

@Suite("The command line")
struct CommandTests {
  private func parse(_ line: String) throws -> WakeWordCommand.Command {
    try WakeWordCommand.parse(line.split(separator: " ").map(String.init))
  }

  @Test func parsesEveryMode() throws {
    #expect(try parse("synth") == .synth)
    #expect(try WakeWordCommand.parse([]) == .help)
    #expect(try parse("help") == .help)
    #expect(
      try parse("record calls --phrase hey-uriel --setting far")
        == .recordCalls(phrase: .heyUriel, setting: .far, count: 20))
    #expect(
      try parse("record calls --setting media --count 5 --phrase uriel")
        == .recordCalls(phrase: .uriel, setting: .media, count: 5))
    #expect(
      try parse("record background --kind talk --minutes 60")
        == .recordBackground(kind: .talk, minutes: 60))
    #expect(try parse("replay --engine apple") == .replay(.apple(context: false), paths: []))
    #expect(
      try parse("replay --engine apple --context on audio/synthetic a.wav")
        == .replay(.apple(context: true), paths: ["audio/synthetic", "a.wav"]))
    #expect(try parse("live --engine apple --context off") == .live(.apple(context: false)))
  }

  @Test(arguments: [
    "record", "record calls --phrase uriel", "record calls --phrase hello --setting near",
    "record calls --phrase uriel --setting near --count 0",
    "record calls --phrase uriel --setting near --count", "record background --kind talk",
    "record background --kind talk --minutes 60 --count 3", "replay", "replay --engine sherpa",
    "replay --engine apple --context maybe", "live --engine apple audio", "synth now",
    "synth --engine apple", "dance",
  ])
  func refusesWhatAModeDoesNotTake(_ line: String) {
    #expect(throws: SpikeError.self) { try parse(line) }
  }
}

/// Needs `say` with the Kanya voice and Apple's Thai dictation model; both ship with this Mac.
@Suite("The Apple engine on a synthetic call", .tags(.speechModel))
struct AppleEngineTests {
  @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/say")))
  func hearsKanyaSayTheName() async throws {
    guard await DictationTranscriber.supportedLocale(equivalentTo: AppleEngine.locale) != nil
    else { return }  // No Thai dictation on this Mac: nothing to check.
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "wakeword-engine-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let samples = try Synth.Say(folder: folder)("Kanya", "วันนี้อากาศดีมาก ยูเรียล เปิด Safari ให้หน่อย")
    let engine = AppleEngine(usesContext: false)
    try await engine.prepare()
    let (audio, feed) = AsyncStream<[Float]>.makeStream()
    feed.yield(samples)
    feed.finish()
    var detections: [Detection] = []
    var words = 0
    for try await event in engine.listen(to: audio) {
      switch event {
      case .detection(let detection): detections.append(detection)
      case .transcript(let pieces): words += pieces.count
      }
    }
    let uriel = try #require(detections.first { $0.phrase == .uriel })
    let duration = Double(samples.count) / SpikeAudio.sampleRate
    #expect(uriel.time > 0.5 && uriel.time <= duration + 0.1)
    #expect(!detections.contains { $0.phrase == .heyUriel })
    #expect(words > 1)
  }
}

extension Tag {
  @Tag static var speechModel: Self
}
