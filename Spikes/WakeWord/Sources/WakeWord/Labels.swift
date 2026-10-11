import Foundation

/// The two wake phrases the spike measures; the owner picks one with the data.
enum Phrase: String, Codable, Sendable, CaseIterable, Comparable {
  case uriel
  case heyUriel = "hey-uriel"

  /// How the cue and the summary write it.
  var spoken: String { self == .uriel ? "Uriel" : "Hey Uriel" }

  static func < (lhs: Phrase, rhs: Phrase) -> Bool {
    allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
  }
}

/// One cue: the moment the terminal told the owner what to say.
struct Cue: Codable, Sendable, Equatable {
  /// Seconds from the start of the recording.
  var time: Double
  /// What the cue asked for, such as `Uriel … ตั้งเวลาห้านาที`.
  var text: String
}

/// The label file next to each recording (`name.json` beside `name.wav`).
struct SessionLabel: Codable, Sendable, Equatable {
  enum Kind: String, Codable, Sendable {
    /// The owner says the wake phrase at each cue.
    case calls
    /// No wake phrase at all; every detection is a false trigger.
    case background
  }

  var kind: Kind
  /// The wake phrase of a calls session; `nil` for background.
  var phrase: Phrase?
  /// `near`, `far` or `media` for calls, `media` or `talk` for background; synthetic sessions
  /// start with `synthetic-` so they never mix with the owner's recordings in the summary.
  var setting: String
  var recorded: Date
  var duration: Double
  /// A detection counts as a hit when it falls in [cue, cue + window].
  var window: Double
  var cues: [Cue]

  /// Seconds after a cue in which a detection counts as a hit: the owner reads the cue, says the
  /// phrase and the engine reports it.
  static let defaultWindow = 6.0

  var isSynthetic: Bool { setting.hasPrefix("synthetic") }

  /// The label beside `wav`.
  static func url(for wav: URL) -> URL {
    wav.deletingPathExtension().appendingPathExtension("json")
  }

  static func read(for wav: URL) throws -> SessionLabel {
    try decoder.decode(SessionLabel.self, from: Data(contentsOf: url(for: wav)))
  }

  func write(for wav: URL) throws {
    try Self.encoder.encode(self).write(to: Self.url(for: wav))
  }

  static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

/// Where the spike keeps its files, found from this source file so the shell's folder does not
/// matter. Both folders are git-ignored: recordings of the owner never leave the Mac.
enum SpikePaths {
  static let package = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  static let audio = package.appending(path: "audio", directoryHint: .isDirectory)
  static let synthetic = audio.appending(path: "synthetic", directoryHint: .isDirectory)
  static let results = package.appending(path: "results", directoryHint: .isDirectory)

  /// `yyyy-MM-dd-HHmmss`, so file and folder names sort by time.
  static func stamp(_ date: Date = .now) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return formatter.string(from: date)
  }

  /// Every `.wav` under `paths` (files, or folders searched recursively), once each, sorted by
  /// path.
  static func recordings(in paths: [URL]) -> [URL] {
    var found: [URL] = []
    for path in paths {
      var isFolder: ObjCBool = false
      guard
        FileManager.default.fileExists(
          atPath: path.path(percentEncoded: false), isDirectory: &isFolder)
      else { continue }
      if !isFolder.boolValue {
        if path.pathExtension.lowercased() == "wav" { found.append(path) }
        continue
      }
      let walker = FileManager.default.enumerator(at: path, includingPropertiesForKeys: nil)
      while let url = walker?.nextObject() as? URL {
        if url.pathExtension.lowercased() == "wav" { found.append(url) }
      }
    }
    return Set(found.map(\.standardizedFileURL)).sorted { $0.path < $1.path }
  }
}
