import AVFoundation
import UrielCore

/// How long the voice takes to start speaking, kept as `tts.json`.
struct SpeechStartResult: Codable, Sendable {
  var date: Date
  var voiceName: String
  var voiceIdentifier: String
  var quality: String
  /// Seconds from `speak` to `didStart` for the synthesizer's first utterance.
  var cold: Double
  /// The same for every later sentence, each spoken once the one before it has finished.
  var warm: [Double]
}

/// Measures `speak` to `didStart` with the voice Uriel would pick, at volume 0, so it is silent.
///
/// It is local and independent of the API, so it runs on its own. Each sentence starts on an idle
/// synthesizer, as Uriel's first sentence of a reply does.
@MainActor
func measureSpeechStart(sentences: [String]) async throws -> SpeechStartResult {
  guard let voice = rankedVoices().first else {
    throw SpikeError("No female English voice is installed.")
  }
  // Read before speaking: the synthesizer may report a smaller variant of the voice afterwards.
  let (name, identifier) = (voice.name, voice.identifier)
  let quality =
    switch voice.quality {
    case .premium: "premium"
    case .enhanced: "enhanced"
    default: "default"
    }
  let (events, continuation) = AsyncStream<SpeechEvent>.makeStream()
  let delegate = SpeechEvents(continuation: continuation)
  let synthesizer = AVSpeechSynthesizer()
  synthesizer.delegate = delegate
  var iterator = events.makeAsyncIterator()
  var delays: [Double] = []
  for sentence in sentences {
    let utterance = AVSpeechUtterance(string: sentence)
    utterance.voice = voice
    utterance.volume = 0
    let start = ContinuousClock.now
    synthesizer.speak(utterance)
    var started: ContinuousClock.Instant?
    while let event = await iterator.next() {
      if case .started(let instant) = event { started = instant }
      if case .finished = event { break }
    }
    guard let started else { throw SpikeError("The synthesizer finished without starting.") }
    delays.append((started - start).seconds)
  }
  return SpeechStartResult(
    date: .now, voiceName: name, voiceIdentifier: identifier, quality: quality,
    cold: delays.first ?? 0, warm: Array(delays.dropFirst()))
}

/// Female English voices, best first: premium, then enhanced, then default quality (docs/plan.md,
/// Phase 1 step 4). Among equals, Samantha first, then US English, then by name. Novelty voices
/// and Personal Voice are left out.
func rankedVoices() -> [AVSpeechSynthesisVoice] {
  AVSpeechSynthesisVoice.speechVoices()
    .filter {
      $0.language.hasPrefix("en") && $0.gender == .female
        && !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
    }
    .sorted { lhs, rhs in
      func rank(_ voice: AVSpeechSynthesisVoice) -> (Int, Int, Int, String) {
        (
          -voice.quality.rawValue, voice.name == "Samantha" ? 0 : 1,
          voice.language == "en-US" ? 0 : 1, voice.name
        )
      }
      return rank(lhs) < rank(rhs)
    }
}

/// About thirty sentences from the dry run's scripted answers, as Uriel would speak them.
func sampleSentences(count: Int = 30) -> [String] {
  var splitter = SentenceSplitter()
  let sentences = Fixtures.utterances.flatMap(\.scriptedReplies).flatMap { reply in
    splitter.append(reply) + splitter.flush()
  }
  return Array(sentences.prefix(count))
}

private enum SpeechEvent: Sendable {
  case started(ContinuousClock.Instant)
  case finished
}

/// Forwards the synthesizer's callbacks, with the time each one arrived.
private final class SpeechEvents: NSObject, AVSpeechSynthesizerDelegate, Sendable {
  private let continuation: AsyncStream<SpeechEvent>.Continuation

  init(continuation: AsyncStream<SpeechEvent>.Continuation) {
    self.continuation = continuation
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance)
  {
    continuation.yield(.started(.now))
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    continuation.yield(.finished)
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    continuation.yield(.finished)
  }
}
