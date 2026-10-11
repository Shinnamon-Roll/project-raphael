import AVFoundation
import Speech

/// Continuous `SpeechAnalyzer` with `DictationTranscriber` in Thai (`SpeechTranscriber` has no
/// Thai), progressive volatile results, and the wake phrase matched in the transcript.
struct AppleEngine: WakeWordEngine {
  static let locale = Locale(identifier: "th-TH")

  /// Whether `AnalysisContext.contextualStrings` carries the wake phrase's spellings.
  var usesContext: Bool

  var name: String { "apple-context-\(usesContext ? "on" : "off")" }

  var details: String {
    "SpeechAnalyzer + DictationTranscriber (th-TH, progressiveLongDictation: volatile results), "
      + "contextual strings \(usesContext ? "on: \(WakePhraseMatcher.contextualStrings)" : "off")"
  }

  /// The progressive long-dictation preset, plus word time ranges on final results so the summary
  /// can show what was heard inside each cue window.
  private func makeTranscriber() -> DictationTranscriber {
    let preset = DictationTranscriber.Preset.progressiveLongDictation
    return DictationTranscriber(
      locale: Self.locale, contentHints: preset.contentHints,
      transcriptionOptions: preset.transcriptionOptions, reportingOptions: preset.reportingOptions,
      attributeOptions: preset.attributeOptions.union([.audioTimeRange]))
  }

  /// Checks Thai is supported, then lets `AssetInventory` install the model or reserve the locale
  /// for this process. Without the reservation the status stays `supported`, not `installed`.
  func prepare() async throws {
    guard await DictationTranscriber.supportedLocale(equivalentTo: Self.locale) != nil else {
      throw SpikeError("DictationTranscriber does not support th-TH on this Mac.")
    }
    let transcriber = makeTranscriber()
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      if request.progress.totalUnitCount > 0 {
        print("Downloading Apple's Thai dictation model through AssetInventory…")
      }
      try await request.downloadAndInstall()
    }
    let status = await AssetInventory.status(forModules: [transcriber])
    guard status == .installed else {
      throw SpikeError("Apple's Thai dictation model is not installed (status: \(status)).")
    }
  }

  func listen(to audio: AsyncStream<[Float]>) -> AsyncThrowingStream<EngineEvent, any Error> {
    AsyncThrowingStream { events in
      let task = Task {
        do {
          try await run(audio, events: events)
          events.finish()
        } catch {
          events.finish(throwing: error)
        }
      }
      events.onTermination = { _ in task.cancel() }
    }
  }

  private func run(
    _ audio: AsyncStream<[Float]>, events: AsyncThrowingStream<EngineEvent, any Error>.Continuation
  ) async throws {
    let transcriber = makeTranscriber()
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    if usesContext {
      let context = AnalysisContext()
      context.contextualStrings[.general] = WakePhraseMatcher.contextualStrings
      try await analyzer.setContext(context)
    }
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    else { throw SpikeError("DictationTranscriber offers no audio format.") }
    try await analyzer.prepareToAnalyze(in: format)

    let (inputs, feed) = AsyncStream<AnalyzerInput>.makeStream()
    try await analyzer.start(inputSequence: inputs)
    let reader = Task {
      var tracker = TranscriptTracker()
      for try await result in transcriber.results {
        let text = String(result.text.characters)
        let (start, end) = (result.range.start.seconds, result.range.end.seconds)
        for detection in tracker.detections(in: text, start: start, end: end) {
          events.yield(.detection(detection))
        }
        guard result.isFinal else { continue }
        let words = result.text.runs.compactMap { run in
          run.audioTimeRange.map {
            Transcript(
              start: $0.start.seconds, end: $0.end.seconds,
              text: String(result.text[run.range].characters))
          }
        }
        events.yield(
          .transcript(words.isEmpty ? [Transcript(start: start, end: end, text: text)] : words))
      }
    }
    do {
      // macOS 26 has no AnalyzerInputConverter (macOS 27), so AVAudioConverter makes the
      // analyzer's format.
      let converter = try FormatConverter(from: SpikeAudio.format, to: format)
      for await samples in audio {
        guard let buffer = SpikeAudio.buffer(samples) else { continue }
        for converted in try converter.convert(buffer) {
          feed.yield(AnalyzerInput(buffer: converted))
        }
      }
      for converted in try converter.flush() { feed.yield(AnalyzerInput(buffer: converted)) }
      feed.finish()
      try await analyzer.finalizeAndFinishThroughEndOfInput()
      try await reader.value
    } catch {
      feed.finish()
      await analyzer.cancelAndFinishNow()
      reader.cancel()
      throw error
    }
  }
}
