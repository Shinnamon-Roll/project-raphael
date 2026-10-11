import Foundation

/// One server-sent event: its `event:` name and its `data:` lines joined with `\n`.
public struct ServerSentEvent: Sendable, Hashable {
  public var event: String?
  public var data: String

  public init(event: String?, data: String) {
    self.event = event
    self.data = data
  }
}

/// A line-based server-sent events parser.
///
/// Feed it one line at a time without the line ending. A blank line ends an event, lines that
/// start with `:` are comments, and several `data:` lines join with `\n`.
public struct ServerSentEventParser: Sendable {
  private var event: String?
  private var data: [String] = []

  public init() {}

  /// Reads one line and returns the event it completes, if any.
  public mutating func parse(line: String) -> ServerSentEvent? {
    if line.isEmpty {
      defer { (event, data) = (nil, []) }
      // An event with no data line is not dispatched.
      return data.isEmpty ? nil : ServerSentEvent(event: event, data: data.joined(separator: "\n"))
    }
    if line.hasPrefix(":") { return nil }
    let field: Substring
    var value: Substring = ""
    if let colon = line.firstIndex(of: ":") {
      field = line[..<colon]
      value = line[line.index(after: colon)...]
      if value.first == " " { value = value.dropFirst() }
    } else {
      field = line[...]
    }
    switch field {
    case "event": event = String(value)
    case "data": data.append(String(value))
    default: break  // `id`, `retry` and unknown fields are not used by the Claude API.
    }
    return nil
  }

  /// Splits a byte stream into lines, dropping `\n` or `\r\n` and keeping empty lines.
  ///
  /// Foundation's `AsyncBytes.lines` drops empty lines, so it cannot find where an event ends.
  /// shortcut: a lone `\r` does not end a line; the Claude API ends lines with `\n`.
  public static func lines<Bytes: AsyncSequence>(
    from bytes: sending Bytes
  ) -> AsyncThrowingStream<String, any Error>
  where Bytes: SendableMetatype, Bytes.Element == UInt8 {
    let (lines, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
    let task = Task {
      do {
        var line: [UInt8] = []
        for try await byte in bytes {
          guard byte == UInt8(ascii: "\n") else {
            line.append(byte)
            continue
          }
          if line.last == UInt8(ascii: "\r") { line.removeLast() }
          continuation.yield(String(decoding: line, as: UTF8.self))
          line.removeAll(keepingCapacity: true)
        }
        if !line.isEmpty { continuation.yield(String(decoding: line, as: UTF8.self)) }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { _ in task.cancel() }
    return lines
  }
}
