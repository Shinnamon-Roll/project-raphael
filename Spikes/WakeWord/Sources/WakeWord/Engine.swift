import Foundation

/// A wake-word engine under test. It hears 16 kHz mono samples and reports each wake phrase it
/// hears, with the audio time it heard it at, so replay and live mode can run any engine the same
/// way. sherpa-onnx keyword spotting plugs in here next (#29).
protocol WakeWordEngine: Sendable {
  /// A short name for the results folder and the summary, such as `apple-context-off`.
  var name: String { get }
  /// One line for the summary: the engine and its settings.
  var details: String { get }
  /// Loads or installs what the engine needs once, before the first stream.
  func prepare() async throws
  /// Listens to `audio`, contiguous chunks of 16 kHz mono samples starting at audio time 0, and
  /// reports events until the audio ends. Replay feeds it faster than real time.
  func listen(to audio: AsyncStream<[Float]>) -> AsyncThrowingStream<EngineEvent, any Error>
}

enum EngineEvent: Sendable, Equatable {
  case detection(Detection)
  /// A final result, word by word where the engine has word times, so the summary can show what
  /// the engine heard around a miss.
  case transcript([Transcript])
}

/// The engine heard a wake phrase.
struct Detection: Codable, Sendable, Equatable {
  var phrase: Phrase
  /// Seconds of audio from the start of the stream when the engine reported it.
  var time: Double
  /// What the engine heard, such as the matched spelling in the transcript.
  var heard: String
}

struct Transcript: Codable, Sendable, Equatable {
  var start: Double
  var end: Double
  var text: String
}

/// Turns a transcriber's results into one detection per spoken phrase.
///
/// Volatile results repeat and extend the text of the same stretch of audio until it is final,
/// and the final results may cut that stretch up differently. So a result's matches are new only
/// beyond the detections already reported inside its audio range. A detection's time is the end
/// of the result that first holds it, the earliest audio time the transcriber could know it.
///
/// shortcut: when a final result ends between a match and the moment it was reported (`slack`),
/// the next stretch may miss a new match; upgrade to word time ranges (`audioTimeRange`, on final
/// results only in macOS 26) if replay shows misses next to hits.
struct TranscriptTracker {
  /// How far past a result's end its first detection can lie: the step between volatile results.
  static let slack = 1.0

  private(set) var reported: [Detection] = []

  /// The new detections in one result covering `start...end` seconds of audio.
  mutating func detections(in text: String, start: Double, end: Double) -> [Detection] {
    var found: [Detection] = []
    for phrase in Phrase.allCases {
      let already = reported.filter {
        $0.phrase == phrase && (start...(end + Self.slack)).contains($0.time)
      }.count
      for match in WakePhraseMatcher.matches(of: phrase, in: text).dropFirst(already) {
        found.append(Detection(phrase: phrase, time: end, heard: match.heard))
      }
    }
    reported += found
    return found
  }
}

/// User and system CPU time of this process so far, in seconds.
func processCPUSeconds() -> Double {
  var usage = rusage()
  getrusage(RUSAGE_SELF, &usage)
  func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
  return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

/// User and system CPU time so far of the system's speech service, where `SpeechAnalyzer` runs
/// `DictationTranscriber` out of process (seen during replay on 2026-10-12); `nil` when it is not
/// running or cannot be read.
///
/// shortcut: it counts every client of the shared service, such as dictation at the same time, and
/// a service that restarts mid-file loses its earlier time; upgrade to `powermetrics` (needs sudo)
/// for a precise per-task figure with power.
func speechServiceCPUSeconds() -> Double? {
  var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
  let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
  var timebase = mach_timebase_info_data_t()
  mach_timebase_info(&timebase)
  var total: Double?
  for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = Int(proc_pidpath(pid, &path, UInt32(path.count)))
    let name = String(
      decoding: path.prefix(max(length, 0)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    guard name.hasSuffix("/localspeechrecognition") else { continue }
    var info = rusage_info_v0()
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
      }
    }
    guard status == 0 else { continue }
    let ticks = Double(info.ri_user_time + info.ri_system_time)
    total = (total ?? 0) + ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9
  }
  return total
}

/// The CPU seconds a process used between two readings. A process that was not running at the
/// first reading, or reads lower because it restarted, counts from zero.
func cpuDelta(from before: Double?, to after: Double?) -> Double? {
  guard let after else { return nil }
  return after >= (before ?? 0) ? after - (before ?? 0) : after
}
