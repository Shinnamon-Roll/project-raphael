import AVFoundation

/// The spike's audio format: 16 kHz mono, as the wake-word engines take it.
enum SpikeAudio {
  static let sampleRate = 16_000.0

  /// 32-bit float samples, one channel, in memory.
  static let format = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

  /// 16-bit PCM WAV on disk.
  static let fileSettings: [String: any Sendable] = [
    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
  ]

  /// Reads a whole WAV as 16 kHz mono samples. Files in another format are converted.
  static func read(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let frames = AVAudioFrameCount(file.length)
    guard frames > 0 else { return [] }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
    else { throw SpikeError("Cannot read \(url.lastPathComponent): no buffer.") }
    try file.read(into: buffer)
    if file.processingFormat == format { return samples(of: buffer) }
    let converter = try FormatConverter(from: file.processingFormat, to: format)
    return samples(of: try converter.convert(buffer) + converter.flush())
  }

  /// The samples of a 16 kHz mono float buffer.
  static func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
    guard let channel = buffer.floatChannelData else { return [] }
    return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
  }

  static func samples(of buffers: [AVAudioPCMBuffer]) -> [Float] {
    buffers.flatMap { samples(of: $0) }
  }

  /// A 16 kHz mono float buffer holding `samples`.
  static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
    }
    return buffer
  }
}

/// Appends 16 kHz mono samples to a 16-bit WAV file.
final class WAVWriter {
  let url: URL
  private var file: AVAudioFile?
  private(set) var frames = 0

  init(url: URL) throws {
    self.url = url
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    file = try AVAudioFile(
      forWriting: url, settings: SpikeAudio.fileSettings, commonFormat: .pcmFormatFloat32,
      interleaved: false)
  }

  var duration: Double { Double(frames) / SpikeAudio.sampleRate }

  func append(_ samples: [Float]) throws {
    guard !samples.isEmpty, let file, let buffer = SpikeAudio.buffer(samples) else { return }
    try file.write(from: buffer)
    frames += samples.count
  }

  /// Writes the header, so the file is complete; later appends are dropped.
  func close() {
    file?.close()
    file = nil
  }

  /// Writes a whole file in one go.
  static func write(_ samples: [Float], to url: URL) throws {
    let writer = try WAVWriter(url: url)
    try writer.append(samples)
    writer.close()
  }
}

/// Converts PCM buffers between formats and sample rates, keeping the converter's state between
/// calls so a stream of buffers resamples without clicks.
final class FormatConverter {
  let output: AVAudioFormat
  private let converter: AVAudioConverter

  init(from input: AVAudioFormat, to output: AVAudioFormat) throws {
    guard let converter = AVAudioConverter(from: input, to: output) else {
      throw SpikeError("Cannot convert \(input) to \(output).")
    }
    // Mix a multichannel microphone down instead of keeping only its first channel.
    converter.downmix = true
    self.converter = converter
    self.output = output
  }

  /// Converts one buffer. The converter may hold back a few frames until the next call.
  func convert(_ buffer: AVAudioPCMBuffer) throws -> [AVAudioPCMBuffer] {
    try run(input: buffer)
  }

  /// The frames the converter still holds, at the end of the stream.
  func flush() throws -> [AVAudioPCMBuffer] { try run(input: nil) }

  private func run(input: AVAudioPCMBuffer?) throws -> [AVAudioPCMBuffer] {
    let ratio = output.sampleRate / converter.inputFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(input?.frameLength ?? 0) * ratio) + 1_024
    let pending = Pending(input)
    var buffers: [AVAudioPCMBuffer] = []
    while true {
      guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { break }
      var error: NSError?
      let status = converter.convert(to: out, error: &error) { _, status in
        guard let buffer = pending.take() else {
          status.pointee = input == nil ? .endOfStream : .noDataNow
          return nil
        }
        status.pointee = .haveData
        return buffer
      }
      if status == .error {
        throw SpikeError("Audio conversion failed: \(error?.localizedDescription ?? "unknown").")
      }
      if out.frameLength > 0 { buffers.append(out) }
      if status != .haveData || out.frameLength < out.frameCapacity { break }
    }
    return buffers
  }

  /// The one buffer the converter's input block hands over, once.
  private final class Pending: @unchecked Sendable {
    // Safe: AVAudioConverter calls the input block synchronously inside `convert(to:error:)`,
    // on the calling thread, so `buffer` is never touched from two threads.
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer?) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
      defer { buffer = nil }
      return buffer
    }
  }
}

/// A failure the spike explains to the owner and exits on.
struct SpikeError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
