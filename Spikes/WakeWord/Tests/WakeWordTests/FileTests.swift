import AVFoundation
import Testing

@testable import WakeWord

/// A fresh folder in the temporary directory, removed by the caller.
private func scratchFolder() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appending(
    path: "wakeword-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@Suite("Label files and recordings on disk")
struct FileTests {
  @Test func labelRoundTripsBesideItsRecording() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let wav = folder.appending(path: "calls-hey-uriel-far-2026-10-12-120000.wav")
    let label = SessionLabel(
      kind: .calls, phrase: .heyUriel, setting: "far", recorded: Date(timeIntervalSince1970: 1_000),
      duration: 212.5, window: 6, cues: [Cue(time: 4.6, text: "Hey Uriel … ตั้งเวลาห้านาที")])
    try label.write(for: wav)
    #expect(
      SessionLabel.url(for: wav).lastPathComponent == "calls-hey-uriel-far-2026-10-12-120000.json")
    #expect(try SessionLabel.read(for: wav) == label)
    let json = try String(contentsOf: SessionLabel.url(for: wav), encoding: .utf8)
    #expect(json.contains("\"phrase\" : \"hey-uriel\""))
    #expect(!label.isSynthetic)
    #expect(
      SessionLabel(
        kind: .background, phrase: nil, setting: "synthetic-talk", recorded: .now, duration: 1,
        window: 6, cues: []
      ).isSynthetic)
  }

  @Test func wavRoundTripsAt16kHzMono() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "tone.wav")
    let samples = (0..<16_000).map { Float(sin(Double($0) * 0.1)) * 0.5 }
    try WAVWriter.write(samples, to: url)
    let file = try AVAudioFile(forReading: url)
    #expect(file.fileFormat.sampleRate == 16_000)
    #expect(file.fileFormat.channelCount == 1)
    #expect(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
    let back = try SpikeAudio.read(url)
    #expect(back.count == samples.count)
    // 16-bit quantization.
    #expect(zip(samples, back).allSatisfy { abs($0 - $1) < 1e-4 })
  }

  @Test func appendingKeepsCountAndDuration() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let writer = try WAVWriter(url: folder.appending(path: "nested/chunk.wav"))
    try writer.append(Array(repeating: 0.1, count: 8_000))
    try writer.append([])
    try writer.append(Array(repeating: -0.1, count: 8_000))
    writer.close()
    #expect(writer.duration == 1)
    #expect(try SpikeAudio.read(writer.url).count == 16_000)
  }

  @Test func readingConvertsOtherRatesAndChannelsTo16kHzMono() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "stereo.wav")
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
    buffer.frameLength = 44_100
    for channel in 0..<2 {
      for index in 0..<44_100 { buffer.floatChannelData![channel][index] = 0.25 }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    file.close()
    let samples = try SpikeAudio.read(url)
    #expect(abs(samples.count - 16_000) <= 2)
    // A constant level stays about the same in the middle of the file.
    #expect(abs(samples[8_000] - 0.25) < 0.05)
  }

  @Test func recordingsAreFoundRecursivelyAndSorted() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["b.wav", "synthetic/a.wav", "notes.json", "synthetic/c.WAV"] {
      let url = folder.appending(path: name)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: url.path, contents: Data())
    }
    let found = SpikePaths.recordings(in: [
      folder, folder.appending(path: "b.wav"), folder.appending(path: "missing"),
    ])
    #expect(found.map(\.lastPathComponent) == ["b.wav", "a.wav", "c.WAV"])
  }

  @Test func spikeFoldersSitInThePackage() {
    #expect(SpikePaths.package.lastPathComponent == "WakeWord")
    #expect(SpikePaths.audio.path.hasSuffix("Spikes/WakeWord/audio"))
    #expect(SpikePaths.results.path.hasSuffix("Spikes/WakeWord/results"))
  }
}
