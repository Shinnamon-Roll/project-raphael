import Foundation

/// One cue and what the engine did with it.
struct CallResult: Codable, Sendable, Equatable {
  var cue: Cue
  /// When the owner started speaking inside the cue's window, from the audio energy.
  var onset: Double?
  /// The first detection of the session's phrase inside the window; `nil` is a miss.
  var detection: Detection?
  /// For a miss, the first detection of the session's phrase after the window and before the next
  /// cue: the call, reported too late to count as a hit.
  var late: Detection?

  /// Seconds from the speech onset to the detection; `nil` for a miss or with no clear onset.
  var delay: Double? {
    guard let detection, let onset else { return nil }
    return detection.time - onset
  }
}

/// How one recording scored.
struct FileScore: Codable, Sendable, Equatable {
  var calls: [CallResult]
  /// Detections of either phrase outside every cue window and late call; in background audio, all
  /// of them.
  var falseTriggers: [Detection]
  /// Seconds of audio outside the cue windows and late calls, the time the false triggers are
  /// counted over.
  var quietSeconds: Double
}

enum Scoring {
  /// Scores `detections` against `label`.
  ///
  /// - A detection of the session's phrase in [cue, cue + window] is that cue's hit; later ones in
  ///   the window are repeats.
  /// - For a miss, the first detection of the session's phrase after the window and before the
  ///   next cue is the call reported late: neither a hit nor a false trigger, and the time up to it
  ///   is not quiet.
  /// - Any other detection, of either phrase, outside those spans is a false trigger.
  static func score(_ label: SessionLabel, detections: [Detection], samples: [Float]) -> FileScore {
    let cues = label.cues.sorted { $0.time < $1.time }
    var used = Set<Int>()
    func first(from start: Double, to end: Double, after: Bool = false) -> Int? {
      detections.indices.first {
        let time = detections[$0].time
        return !used.contains($0) && detections[$0].phrase == label.phrase
          && (after ? time > start && time < end : time >= start && time <= end)
      }
    }
    let calls = cues.enumerated().map { index, cue in
      let windowEnd = cue.time + label.window
      let hit = first(from: cue.time, to: windowEnd)
      let next = index + 1 < cues.count ? cues[index + 1].time : .infinity
      let late = hit == nil ? first(from: windowEnd, to: next, after: true) : nil
      for chosen in [hit, late].compactMap({ $0 }) { used.insert(chosen) }
      return CallResult(
        cue: cue, onset: onset(in: samples, cue: cue.time, window: label.window),
        detection: hit.map { detections[$0] }, late: late.map { detections[$0] })
    }
    let spans = calls.map { $0.cue.time...max($0.cue.time + label.window, $0.late?.time ?? 0) }
    let falseTriggers = detections.filter { detection in
      !spans.contains { $0.contains(detection.time) }
    }
    return FileScore(
      calls: calls, falseTriggers: falseTriggers,
      quietSeconds: quietSeconds(duration: label.duration, outside: spans))
  }

  /// `duration` minus the union of `spans` inside it.
  static func quietSeconds(duration: Double, outside spans: [ClosedRange<Double>]) -> Double {
    var covered = 0.0
    var reach = 0.0
    for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
      let from = max(span.lowerBound, reach, 0)
      let to = min(span.upperBound, duration)
      if to > from { covered += to - from }
      reach = max(reach, to)
    }
    return max(duration - covered, 0)
  }

  /// 20 ms frames at 16 kHz.
  static let frame = 320

  /// The first moment in [cue, cue + window] where the audio stays above the noise floor for
  /// 60 ms; the floor is the quiet 20th percentile of the two seconds before the cue.
  ///
  /// shortcut: a plain energy threshold (floor + 9.5 dB) misses soft far-field speech and fires on
  /// loud media; upgrade to SpeechDetector or a VAD if many calls show no onset.
  static func onset(
    in samples: [Float], cue: Double, window: Double, sampleRate: Double = SpikeAudio.sampleRate
  ) -> Double? {
    func frames(from start: Double, to end: Double) -> [(time: Double, rms: Float)] {
      let first = max(Int(start * sampleRate) / frame, 0)
      let last = min(Int(end * sampleRate), samples.count) / frame
      guard last > first else { return [] }
      return (first..<last).map { index in
        let slice = samples[(index * frame)..<((index + 1) * frame)]
        let rms = (slice.reduce(0) { $0 + $1 * $1 } / Float(frame)).squareRoot()
        return (Double(index * frame) / sampleRate, rms)
      }
    }
    let inside = frames(from: cue, to: cue + window)
    let before = frames(from: cue - 2, to: cue)
    guard !inside.isEmpty else { return nil }
    let floor = percentile(20, of: (before.isEmpty ? inside : before).map { Double($0.rms) }) ?? 0
    let threshold = Float(max(floor * 3, 0.003))
    var run = 0
    for (index, frame) in inside.enumerated() {
      run = frame.rms >= threshold ? run + 1 : 0
      if run == 3 { return inside[index - 2].time }
    }
    return nil
  }
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

/// False triggers over a stretch of audio.
struct Rate: Equatable {
  var count: Int
  var seconds: Double

  var hours: Double { seconds / 3_600 }
  /// `nil` with no audio.
  var perHour: Double? { seconds > 0 ? Double(count) / hours : nil }

  static func + (lhs: Rate, rhs: Rate) -> Rate {
    Rate(count: lhs.count + rhs.count, seconds: lhs.seconds + rhs.seconds)
  }
}
