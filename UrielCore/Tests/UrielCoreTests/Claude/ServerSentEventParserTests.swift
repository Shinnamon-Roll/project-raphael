import Testing
import UrielCore

@Suite("Server-sent events")
struct ServerSentEventParserTests {
  private func parse(_ lines: [String]) -> [ServerSentEvent] {
    var parser = ServerSentEventParser()
    return lines.compactMap { parser.parse(line: $0) }
  }

  private func lines(of text: String) async throws -> [String] {
    let bytes = AsyncStream<UInt8> { continuation in
      for byte in text.utf8 { continuation.yield(byte) }
      continuation.finish()
    }
    var lines: [String] = []
    for try await line in ServerSentEventParser.lines(from: bytes) { lines.append(line) }
    return lines
  }

  @Test func joinsDataLinesAndSkipsCommentsAndOtherFields() {
    let events = parse([
      ": a comment", "event: a", "data: one", "data:two", "id: 7", "retry", "",
    ])
    #expect(events == [ServerSentEvent(event: "a", data: "one\ntwo")])
  }

  @Test func eventWithoutDataIsNotDispatchedAndStateResets() {
    let events = parse(["event: lonely", "", "data: {}", ""])
    #expect(events == [ServerSentEvent(event: nil, data: "{}")])
  }

  @Test func eventEndsOnlyAtBlankLine() {
    #expect(parse(["event: ping", #"data: {"type":"ping"}"#]).isEmpty)
  }

  @Test func splitsBytesOnLineFeedAndCarriageReturnLineFeed() async throws {
    #expect(try await lines(of: "a\r\nb\n\nc") == ["a", "b", "", "c"])
  }

  @Test func crlfStreamParsesLikeLineFeedStream() async throws {
    let text = "event: ping\r\ndata: {\"type\":\"ping\"}\r\n\r\n"
    let events = parse(try await lines(of: text))
    #expect(events == [ServerSentEvent(event: "ping", data: #"{"type":"ping"}"#)])
  }
}
