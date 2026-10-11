import Foundation

/// One recording replayed through one engine, kept in `files.json`.
struct FileRun: Codable, Sendable, Equatable {
  /// Relative to `Spikes/WakeWord`.
  var path: String
  var label: SessionLabel
  var detections: [Detection]
  var transcripts: [Transcript]
  var score: FileScore
  var cpuSeconds: Double
  /// The system speech service's CPU over the same time, when it could be read.
  var serviceCPUSeconds: Double?
  var wallSeconds: Double
}

/// Replays every labelled recording in `paths` through `engine` and writes a results folder with
/// `summary.md` and `files.json`. Returns the summary.
func replay(_ engine: some WakeWordEngine, paths: [URL]) async throws -> String {
  let recordings = SpikePaths.recordings(in: paths)
  guard !recordings.isEmpty else {
    throw SpikeError("No recordings found. Run `wakeword synth`, or record some first.")
  }
  try await engine.prepare()
  var runs: [FileRun] = []
  for wav in recordings {
    let relative = wav.path.replacingOccurrences(
      of: SpikePaths.package.standardizedFileURL.path + "/", with: "")
    let label: SessionLabel
    do {
      label = try SessionLabel.read(for: wav)
    } catch {
      print("Skipping \(relative): no readable label beside it (\(error.localizedDescription)).")
      continue
    }
    let samples = try SpikeAudio.read(wav)
    print("Replaying \(relative) (\(String(format: "%.1f", label.duration / 60)) min)…")
    let (stream, feed) = AsyncStream<[Float]>.makeStream()
    // 0.1 s chunks, about what the live tap delivers.
    for start in stride(from: 0, to: samples.count, by: 1_600) {
      feed.yield(Array(samples[start..<min(start + 1_600, samples.count)]))
    }
    feed.finish()
    let cpu = processCPUSeconds()
    let serviceCPU = speechServiceCPUSeconds()
    let clock = ContinuousClock.now
    var detections: [Detection] = []
    var transcripts: [Transcript] = []
    for try await event in engine.listen(to: stream) {
      switch event {
      case .detection(let detection): detections.append(detection)
      case .transcript(let words): transcripts += words
      }
    }
    runs.append(
      FileRun(
        path: relative, label: label, detections: detections, transcripts: transcripts,
        score: Scoring.score(label, detections: detections, samples: samples),
        cpuSeconds: processCPUSeconds() - cpu,
        serviceCPUSeconds: cpuDelta(from: serviceCPU, to: speechServiceCPUSeconds()),
        wallSeconds: (ContinuousClock.now - clock) / .seconds(1)))
  }
  let summary = Report(engine: engine.name, details: engine.details, date: .now, runs: runs).summary
  let folder = SpikePaths.results.appending(
    path: "\(SpikePaths.stamp())-replay-\(engine.name)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  try SessionLabel.encoder.encode(runs).write(to: folder.appending(path: "files.json"))
  try Data(summary.utf8).write(to: folder.appending(path: "summary.md"))
  return summary + "\nResults: \(folder.path(percentEncoded: false))\n"
}

/// `summary.md`: hits, false triggers, delay and CPU per phrase and setting.
struct Report {
  var engine: String
  var details: String
  var date: Date
  var runs: [FileRun]

  static let callSettings = ["near", "far", "media"]

  var summary: String {
    let calls = runs.filter { $0.label.kind == .calls }
    let background = runs.filter { $0.label.kind == .background }
    let callMinutes = calls.reduce(0) { $0 + $1.label.duration } / 60
    let backgroundHours = background.reduce(0) { $0 + $1.label.duration } / 3_600
    var lines = [
      "# Wake-word replay: \(engine)", "",
      "\(details).", "",
      "\(SpikePaths.stamp(date)): \(runs.count) recordings, \(format(callMinutes, 1)) min of calls "
        + "and \(format(backgroundHours, 2)) h of background.", "",
      "Target: at least 57 of 60 calls detected (95 %), and at most 1 false trigger per 8 h "
        + "(0.125 per hour).", "",
    ]
    lines += callTable(calls)
    lines += falseTriggerTable(calls: calls, background: background)
    lines += cpuSection()
    lines += heardSection()
    lines += [
      "## How this is measured", "",
      "- A hit is a detection of the session's phrase within \(format(SessionLabel.defaultWindow, 0)) s "
        + "after its cue; one per cue. A detection of either phrase outside every cue window is a "
        + "false trigger; in background audio every detection is one.",
      "- \"Uriel\" matches the name with or without \"hey\"; \"Hey Uriel\" needs a spelling of hey "
        + "right before the name.",
      "- Detection time is the end of the audio range of the first (volatile) result that holds "
        + "the match. Replay feeds the audio faster than real time, so the delay leaves out the "
        + "transcriber's processing lag in real time; check it with `live`.",
      "- The delay runs from the speech onset in the cue window, found with a plain energy "
        + "threshold; calls with no clear onset are left out of the delay.",
      "- CPU is user + system time: this process from `getrusage`, and the system speech "
        + "service, where DictationTranscriber does its work, from `proc_pid_rusage`.",
      "",
    ]
    return lines.joined(separator: "\n")
  }

  private func callTable(_ calls: [FileRun]) -> [String] {
    guard !calls.isEmpty else { return ["## Calls", "", "No call sessions.", ""] }
    var lines = [
      "## Calls", "",
      "| Phrase | Setting | Hits | Delay p50 | Delay p95 | No onset |",
      "|---|---|---|---|---|---|",
    ]
    for phrase in Phrase.allCases {
      let sessions = calls.filter { $0.label.phrase == phrase }
      guard !sessions.isEmpty else { continue }
      for setting in Self.ordered(Set(sessions.map(\.label.setting))) {
        lines.append(
          callRow(phrase.spoken, setting, sessions.filter { $0.label.setting == setting }))
      }
      let recorded = sessions.filter { !$0.label.isSynthetic }
      if !recorded.isEmpty {
        let results = recorded.flatMap(\.score.calls)
        let hits = results.filter { $0.detection != nil }.count
        let met = Double(hits) >= 0.95 * Double(results.count)
        lines.append(
          callRow(
            "**\(phrase.spoken)**", "recorded, all", recorded,
            note: met ? ", meets the target" : ", misses the target"))
      }
    }
    return lines + [""]
  }

  private func callRow(
    _ phrase: String, _ setting: String, _ sessions: [FileRun], note: String = ""
  ) -> String {
    let results = sessions.flatMap(\.score.calls)
    let hits = results.filter { $0.detection != nil }.count
    let delays = results.compactMap(\.delay)
    let noOnset = results.filter { $0.detection != nil && $0.onset == nil }.count
    return "| \(phrase) | \(setting) | \(hits)/\(results.count)\(note) | "
      + "\(seconds(percentile(50, of: delays))) | \(seconds(percentile(95, of: delays))) | \(noOnset) |"
  }

  private func falseTriggerTable(calls: [FileRun], background: [FileRun]) -> [String] {
    var lines = [
      "## False triggers", "",
      "| Phrase | Audio | False triggers | Hours | Per hour | Per 8 h |",
      "|---|---|---|---|---|---|",
    ]
    for phrase in Phrase.allCases {
      func rate(_ runs: [FileRun]) -> Rate {
        runs.reduce(Rate(count: 0, seconds: 0)) {
          $0
            + Rate(
              count: $1.score.falseTriggers.filter { $0.phrase == phrase }.count,
              seconds: $1.score.quietSeconds)
        }
      }
      var rows: [(String, Rate)] = []
      for setting in Self.ordered(Set(background.map(\.label.setting))) {
        rows.append(
          ("background \(setting)", rate(background.filter { $0.label.setting == setting })))
      }
      let recordedCalls = calls.filter { !$0.label.isSynthetic }
      let syntheticCalls = calls.filter(\.label.isSynthetic)
      if !recordedCalls.isEmpty { rows.append(("outside the cues, recorded", rate(recordedCalls))) }
      if !syntheticCalls.isEmpty {
        rows.append(("outside the cues, synthetic", rate(syntheticCalls)))
      }
      let recorded = rate(recordedCalls + background.filter { !$0.label.isSynthetic })
      if recorded.seconds > 0 { rows.append(("**recorded, all**", recorded)) }
      for (audio, rate) in rows {
        lines.append(
          "| \(phrase.spoken) | \(audio) | \(rate.count) | \(format(rate.hours, 2)) | "
            + "\(rate.perHour.map { format($0, 2) } ?? "–") | "
            + "\(rate.perHour.map { format($0 * 8, 1) } ?? "–") |")
      }
    }
    return lines + [
      "",
      "Two hours of background cannot show 0.125 per hour on its own: none in 2 h is consistent "
        + "with the target, and one in 2 h is already 0.5 per hour.", "",
    ]
  }

  private func cpuSection() -> [String] {
    let cpu = runs.reduce(0) { $0 + $1.cpuSeconds }
    let wall = runs.reduce(0) { $0 + $1.wallSeconds }
    let hours = runs.reduce(0) { $0 + $1.label.duration } / 3_600
    guard hours > 0, wall > 0 else { return [] }
    let service = runs.compactMap(\.serviceCPUSeconds)
    var lines = [
      "## CPU", "",
      "| Process | CPU | Per hour of audio |", "|---|---|---|",
      "| this process (`getrusage`) | \(format(cpu, 1)) s | \(format(cpu / hours, 0)) s |",
    ]
    if service.count == runs.count {
      let total = service.reduce(0, +)
      lines.append(
        "| system speech service (`localspeechrecognition`) | \(format(total, 1)) s | "
          + "\(format(total / hours, 0)) s |")
      lines.append(
        "| **both** | \(format(cpu + total, 1)) s | **\(format((cpu + total) / hours, 0)) s** |")
    }
    lines += [
      "",
      "\(format(hours, 2)) h of audio; replay ran \(format(hours * 3_600 / wall, 0))× faster than "
        + "real time. "
        + (service.count == runs.count
          ? "The speech service is shared, so anything else using speech recognition during the "
            + "replay counts too."
          : "The system speech service could not be read, so only this process is counted."),
      "Power is not measured here; watch `live` with Activity Monitor's Energy tab or "
        + "`sudo powermetrics --samplers tasks`.", "",
    ]
    return lines
  }

  private func heardSection() -> [String] {
    var spellings: [String: Int] = [:]
    for detection in runs.flatMap(\.detections) { spellings[detection.heard, default: 0] += 1 }
    var lines = ["## What the engine heard", ""]
    lines.append(
      spellings.isEmpty
        ? "No matches."
        : "Matched spellings: "
          + spellings.sorted { ($1.value, $0.key) < ($0.value, $1.key) }
          .map { "`\($0.key)` ×\($0.value)" }.joined(separator: ", ") + ".")
    lines.append("")
    var missed: [String] = []
    var falseTriggers: [String] = []
    for run in runs {
      for call in run.score.calls where call.detection == nil {
        let heard = Self.heard(
          in: run.transcripts, from: call.cue.time, to: call.cue.time + run.label.window)
        missed.append(
          "- `\(run.path)` cue at \(format(call.cue.time, 1)) s (\(call.cue.text)): heard “\(heard)”"
        )
      }
      for detection in run.score.falseTriggers {
        let heard = Self.heard(in: run.transcripts, from: detection.time - 3, to: detection.time)
        falseTriggers.append(
          "- `\(run.path)` at \(format(detection.time, 1)) s, \(detection.phrase.spoken) as "
            + "`\(detection.heard)`: “\(heard)”")
      }
    }
    lines += ["### Missed calls", ""] + (missed.isEmpty ? ["None."] : missed) + [""]
    lines +=
      ["### False triggers", ""] + (falseTriggers.isEmpty ? ["None."] : falseTriggers) + [""]
    return lines
  }

  /// The final transcript that overlaps `from...to`, at most 160 characters. Thai words carry no
  /// spaces and Latin words carry their own.
  static func heard(in transcripts: [Transcript], from: Double, to: Double) -> String {
    let text = transcripts.filter { $0.end >= from && $0.start <= to }.map(\.text).joined()
      .trimmingCharacters(in: .whitespaces)
    return text.count > 160 ? String(text.prefix(160)) + "…" : text
  }

  /// near, far, media first, then the rest by name.
  static func ordered(_ settings: Set<String>) -> [String] {
    settings.sorted {
      (callSettings.firstIndex(of: $0) ?? callSettings.count, $0)
        < (callSettings.firstIndex(of: $1) ?? callSettings.count, $1)
    }
  }
}

private func format(_ value: Double, _ digits: Int) -> String {
  String(format: "%.\(digits)f", value)
}

private func seconds(_ value: Double?) -> String {
  value.map { format($0, 2) + " s" } ?? "–"
}
