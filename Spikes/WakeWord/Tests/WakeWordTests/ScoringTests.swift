import Foundation
import Testing

@testable import WakeWord

private func label(
  _ kind: SessionLabel.Kind = .calls, phrase: Phrase? = .uriel, setting: String = "near",
  duration: Double = 60, cues: [Double] = []
) -> SessionLabel {
  SessionLabel(
    kind: kind, phrase: phrase, setting: setting, recorded: Date(timeIntervalSince1970: 0),
    duration: duration, window: 6, cues: cues.map { Cue(time: $0, text: "Uriel") })
}

private func detection(_ time: Double, _ phrase: Phrase = .uriel) -> Detection {
  Detection(phrase: phrase, time: time, heard: "ยูเรียน")
}

@Suite("Scoring calls and false triggers")
struct ScoringTests {
  @Test func aDetectionInsideTheWindowIsAHitAndOutsideIsAFalseTrigger() {
    let score = Scoring.score(
      label(cues: [10, 25, 40]),
      detections: [detection(11.5), detection(31.5), detection(55)], samples: [])
    #expect(score.calls.map { $0.detection?.time } == [11.5, nil, nil])
    // 31.5 is 6.5 s after the cue at 25: outside its window.
    #expect(score.falseTriggers.map(\.time) == [31.5, 55])
    #expect(score.quietSeconds == 60 - 18)
  }

  @Test func theWindowIncludesBothEnds() {
    let score = Scoring.score(
      label(cues: [10, 30]), detections: [detection(10), detection(36)], samples: [])
    #expect(score.calls.allSatisfy { $0.detection != nil })
    #expect(score.falseTriggers.isEmpty)
  }

  @Test func repeatsAndTheOtherPhraseInsideAWindowAreNeitherHitsNorFalseTriggers() {
    let score = Scoring.score(
      label(phrase: .heyUriel, cues: [10]),
      detections: [detection(11, .uriel), detection(12, .heyUriel), detection(13, .heyUriel)],
      samples: [])
    #expect(score.calls.first?.detection == detection(12, .heyUriel))
    #expect(score.falseTriggers.isEmpty)
  }

  @Test func onlyTheSessionsPhraseCanHit() {
    let score = Scoring.score(
      label(phrase: .heyUriel, cues: [10]), detections: [detection(11)], samples: [])
    #expect(score.calls.first?.detection == nil)
  }

  @Test func everyDetectionInBackgroundIsAFalseTrigger() {
    let score = Scoring.score(
      label(.background, phrase: nil, setting: "talk", duration: 600),
      detections: [detection(5), detection(100, .heyUriel)], samples: [])
    #expect(score.calls.isEmpty)
    #expect(score.falseTriggers.count == 2)
    #expect(score.quietSeconds == 600)
  }

  @Test func quietTimeLeavesOutOverlappingAndClippedWindows() {
    let cues = [10, 13, 57].map { Cue(time: $0, text: "") }
    // Windows 10–16 and 13–19 overlap (9 s together); 57–63 is clipped to 57–60 (3 s).
    #expect(Scoring.quietSeconds(duration: 60, cues: cues, window: 6) == 48)
    #expect(Scoring.quietSeconds(duration: 60, cues: [], window: 6) == 60)
  }

  @Test func ratesArePerHourOfQuietAudio() {
    let rate = Rate(count: 1, seconds: 1_800) + Rate(count: 2, seconds: 1_800)
    #expect(rate.perHour == 3)
    #expect(Rate(count: 0, seconds: 0).perHour == nil)
  }

  @Test func onsetIsWhereTheEnergyRisesAfterTheCue() throws {
    let rate = SpikeAudio.sampleRate
    var samples = (0..<Int(12 * rate)).map { Float(sin(Double($0) * 0.37)) * 0.001 }
    // Speech starts 1.2 s after a cue at 5 s.
    for index in Int(6.2 * rate)..<Int(7.5 * rate) {
      samples[index] = Float(sin(Double(index) * 0.05)) * 0.3
    }
    let onset = try #require(Scoring.onset(in: samples, cue: 5, window: 6))
    #expect(abs(onset - 6.2) < 0.03)
    #expect(Scoring.onset(in: samples, cue: 0.5, window: 3) == nil)
    #expect(Scoring.onset(in: [], cue: 0, window: 6) == nil)
  }

  @Test func theDelayRunsFromTheOnset() {
    let call = CallResult(cue: Cue(time: 10, text: ""), onset: 11, detection: detection(12.5))
    #expect(call.delay == 1.5)
    #expect(
      CallResult(cue: Cue(time: 10, text: ""), onset: nil, detection: detection(12)).delay == nil)
  }

  @Test func cpuDeltaCountsAProcessThatStartedLateFromZero() {
    #expect(cpuDelta(from: 2, to: 5) == 3)
    #expect(cpuDelta(from: nil, to: 5) == 5)
    #expect(cpuDelta(from: 5, to: nil) == nil)
    // A restarted service reads lower than before: count the new process from zero.
    #expect(cpuDelta(from: 5, to: 1) == 1)
    #expect(processCPUSeconds() > 0)
  }

  @Test func percentileInterpolatesBetweenRanks() {
    #expect(percentile(50, of: [4, 1, 3, 2]) == 2.5)
    #expect(percentile(95, of: [7]) == 7)
    #expect(percentile(50, of: []) == nil)
  }

  @Test func cuesAreFarEnoughApartForTheirWindows() {
    var generator = SplitMix64(seed: 7)
    let times = Recorder.cueTimes(count: 20, using: &generator)
    #expect(times.count == 20)
    #expect((4...6).contains(times[0]))
    for (earlier, later) in zip(times, times.dropFirst()) {
      #expect((8...12).contains(later - earlier))
      #expect(later - earlier > SessionLabel.defaultWindow)
    }
  }

  @Test func summaryShowsHitsFalseTriggersAndTheTarget() {
    let cues = (0..<20).map { Double($0) * 10 + 5 }
    let calls = FileRun(
      path: "audio/calls-uriel-near.wav", label: label(duration: 205, cues: cues), detections: [],
      transcripts: [],
      score: FileScore(
        calls: cues.enumerated().map { index, cue in
          CallResult(
            cue: Cue(time: cue, text: "Uriel"), onset: cue + 1,
            detection: index == 0 ? nil : detection(cue + 2))
        }, falseTriggers: [], quietSeconds: 85), cpuSeconds: 2, serviceCPUSeconds: 10,
      wallSeconds: 4)
    let background = FileRun(
      path: "audio/background-talk.wav",
      label: label(.background, phrase: nil, setting: "talk", duration: 3_600),
      detections: [detection(100)], transcripts: [Transcript(start: 99, end: 100, text: "ยูเรียน")],
      score: FileScore(calls: [], falseTriggers: [detection(100)], quietSeconds: 3_600),
      cpuSeconds: 30, serviceCPUSeconds: 60, wallSeconds: 100)
    let summary = Report(
      engine: "test", details: "Test engine", date: .now, runs: [calls, background]
    )
    .summary
    #expect(summary.contains("| Uriel | near | 19/20 | 1.00 s | 1.00 s | 0 |"))
    #expect(summary.contains("| **Uriel** | recorded, all | 19/20, meets the target |"))
    #expect(summary.contains("| Uriel | background talk | 1 | 1.00 | 1.00 | 8.0 |"))
    #expect(summary.contains("| Hey Uriel | background talk | 0 | 1.00 | 0.00 | 0.0 |"))
    #expect(summary.contains("| this process (`getrusage`) | 32.0 s |"))
    #expect(summary.contains("| system speech service (`localspeechrecognition`) | 70.0 s |"))
    #expect(summary.contains("| **both** | 102.0 s |"))
    #expect(summary.contains("cue at 5.0 s (Uriel)"))
    #expect(summary.contains("Uriel as `ยูเรียน`: “ยูเรียน”"))
  }
}

/// A seeded generator, so the cue schedule test is repeatable.
struct SplitMix64: RandomNumberGenerator {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
