import Foundation
import Testing
import UrielCore

private struct FakeKey: APIKeyProvider {
  func apiKey() async throws -> String { "test-key-not-real" }
}

private actor SentRequests {
  private(set) var all: [URLRequest] = []
  func append(_ request: URLRequest) { all.append(request) }
}

/// Answers every request with `body`, split into lines as a real response would be.
private struct FakeTransport: HTTPTransport {
  var statusCode = 200
  var headers: [String: String] = [:]
  var body: String
  let sent = SentRequests()

  func send(_ request: URLRequest) async throws -> HTTPStreamResponse {
    await sent.append(request)
    let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    return HTTPStreamResponse(
      statusCode: statusCode, headers: headers,
      lines: AsyncThrowingStream { continuation in
        for line in lines { continuation.yield(line) }
        continuation.finish()
      })
  }
}

private let sampleRequest = MessagesRequest(
  maxTokens: 1024, system: ["You are Uriel."],
  messages: [Message(role: .user, content: [.text("Hi")])], effort: .low)

/// Streams `sampleRequest` through `transport`; returns what was yielded and the closing error.
private func run(_ transport: FakeTransport) async -> (
  events: [ClaudeStreamEvent], error: (any Error)?
) {
  var events: [ClaudeStreamEvent] = []
  do {
    let client = ClaudeClient(keyProvider: FakeKey(), transport: transport)
    for try await event in client.stream(sampleRequest) { events.append(event) }
    return (events, nil)
  } catch {
    return (events, error)
  }
}

private func completed(_ events: [ClaudeStreamEvent]) -> ClaudeResponse? {
  guard case .completed(let response) = events.last else { return nil }
  return response
}

private let messageStart = #"""
  event: message_start
  data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":12,"cache_creation_input_tokens":600,"cache_read_input_tokens":0,"output_tokens":1}}}


  """#

private let messageEnd = #"""
  event: message_delta
  data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":7}}

  event: message_stop
  data: {"type":"message_stop"}


  """#

private let helloText = #"""
  event: content_block_start
  data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

  event: ping
  data: {"type": "ping"}

  event: content_block_delta
  data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

  event: content_block_delta
  data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" there."}}

  event: content_block_stop
  data: {"type":"content_block_stop","index":0}


  """#

@Suite("Claude client streaming")
struct ClaudeClientTests {
  @Test func streamsTextThenCompletesWithStopReasonAndUsage() async throws {
    let result = await run(FakeTransport(body: messageStart + helloText + messageEnd))
    #expect(result.error == nil)
    #expect(result.events.dropLast() == [.textDelta("Hello"), .textDelta(" there.")])
    let response = try #require(completed(result.events))
    #expect(response.content == [.text("Hello there.")])
    #expect(response.stopReason == "end_turn")
    #expect(
      response.usage
        == Usage(
          inputTokens: 12, outputTokens: 7, cacheCreationInputTokens: 600, cacheReadInputTokens: 0))
  }

  @Test func sendsKeyVersionAndRequestBody() async throws {
    let transport = FakeTransport(body: messageStart + helloText + messageEnd)
    _ = await run(transport)
    let sent = await transport.sent.all
    #expect(sent.count == 1)
    let request = try #require(sent.first)
    #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key-not-real")
    #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
    #expect(request.httpBody == (try sampleRequest.jsonData()))
  }

  @Test func joinsToolInputPiecesAtBlockStop() async throws {
    let toolUse = #"""
      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"set_timer","input":{}}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":""}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"seconds\":"}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":" 300, \"la"}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"bel\": \"tea\"}"}}

      event: content_block_stop
      data: {"type":"content_block_stop","index":0}

      event: message_delta
      data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":30}}

      event: message_stop
      data: {"type":"message_stop"}


      """#
    let result = await run(FakeTransport(body: messageStart + toolUse))
    #expect(result.error == nil)
    #expect(result.events.count == 1)
    let response = try #require(completed(result.events))
    #expect(response.stopReason == "tool_use")
    let call = try #require(response.content.first?.toolUse)
    #expect(call.id == "toolu_1")
    #expect(call.name == "set_timer")
    #expect(call.input == ["seconds": .number(300), "label": .string("tea")])
  }

  @Test func errorEventEndsTheStreamWithTypedError() async {
    let partial = #"""
      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}

      event: error
      data: {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}


      """#
    let result = await run(FakeTransport(body: messageStart + partial))
    #expect(result.events == [.textDelta("Hel")])
    #expect(
      result.error as? ClaudeError == .stream(type: "overloaded_error", message: "Overloaded"))
  }

  @Test func ignoresUnknownEventTypes() async throws {
    let unknown = #"""
      event: future_event
      data: {"type":"future_event","anything":1}

      event: another_new_event
      data: not json at all


      """#
    let result = await run(FakeTransport(body: messageStart + unknown + helloText + messageEnd))
    #expect(result.error == nil)
    #expect(try #require(completed(result.events)).content == [.text("Hello there.")])
  }

  @Test func emptyThinkingBlockBeforeTextIsKeptAndNotSpoken() async throws {
    let blocks = #"""
      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-empty"}}

      event: content_block_stop
      data: {"type":"content_block_stop","index":0}

      event: content_block_start
      data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hi."}}

      event: content_block_stop
      data: {"type":"content_block_stop","index":1}


      """#
    let result = await run(FakeTransport(body: messageStart + blocks + messageEnd))
    #expect(result.events.dropLast() == [.textDelta("Hi.")])
    let response = try #require(completed(result.events))
    #expect(response.content.map(\.type) == ["thinking", "text"])
    #expect(
      response.content.first?.json
        == [
          "type": .string("thinking"), "thinking": .string(""), "signature": .string("sig-empty"),
        ])
    #expect(response.content.compactMap(\.text) == ["Hi."])
  }

  /// The stream has no single received byte string, so the test checks the canonical encoding
  /// (sorted keys, compact) byte for byte, which is also what goes back in the next request.
  @Test func assistantMessageRoundTripsWithThinkingSignatureAndUnknownBlock() async throws {
    let blocks = #"""
      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"The owner wants a timer."}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" 5 min = 300 s."}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-abc"}}

      event: content_block_stop
      data: {"type":"content_block_stop","index":0}

      event: content_block_start
      data: {"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"opaque-redacted"}}

      event: content_block_stop
      data: {"type":"content_block_stop","index":1}

      event: content_block_start
      data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"Setting a timer."}}

      event: content_block_stop
      data: {"type":"content_block_stop","index":2}

      event: content_block_start
      data: {"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"toolu_1","name":"set_timer","input":{}}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"{\"seconds\": 300, \"label\": \"tea\"}"}}

      event: content_block_stop
      data: {"type":"content_block_stop","index":3}

      event: content_block_start
      data: {"type":"content_block_start","index":4,"content_block":{"type":"future_block","payload":{"n":1,"flag":true,"list":[null,"x"]}}}

      event: content_block_stop
      data: {"type":"content_block_stop","index":4}


      """#
    let result = await run(FakeTransport(body: messageStart + blocks + messageEnd))
    let response = try #require(completed(result.events))

    let canonical =
      #"[{"signature":"sig-abc","thinking":"The owner wants a timer. 5 min = 300 s.","type":"thinking"},"#
      + #"{"data":"opaque-redacted","type":"redacted_thinking"},"#
      + #"{"text":"Setting a timer.","type":"text"},"#
      + #"{"id":"toolu_1","input":{"label":"tea","seconds":300},"name":"set_timer","type":"tool_use"},"#
      + #"{"payload":{"flag":true,"list":[null,"x"],"n":1},"type":"future_block"}]"#
    let content = JSONValue.array(response.message.content.map { .object($0.json) })
    #expect(String(decoding: try content.jsonData(), as: UTF8.self) == canonical)

    // Sent back as history, the turn encodes to the same JSON, and to the same bytes every time.
    let next = MessagesRequest(
      maxTokens: 1024, system: ["You are Uriel."],
      messages: sampleRequest.messages + [response.message], effort: .low)
    #expect(try next.jsonData() == next.jsonData())
    let body = String(decoding: try next.jsonData(), as: UTF8.self)
    #expect(body.contains(#"{"content":\#(canonical),"role":"assistant"}"#))
  }

  @Test func non2xxBecomesHTTPErrorWithRetryAfter() async {
    let limited = FakeTransport(
      statusCode: 429, headers: ["retry-after": "30"],
      body:
        #"{"type":"error","error":{"type":"rate_limit_error","message":"Rate limited"},"request_id":"req_1"}"#
    )
    #expect(
      await run(limited).error as? ClaudeError
        == .http(
          status: 429, type: "rate_limit_error", message: "Rate limited", retryAfter: .seconds(30)))

    let overloaded = FakeTransport(statusCode: 529, body: "<html>busy</html>")
    #expect(
      await run(overloaded).error as? ClaudeError
        == .http(status: 529, type: nil, message: nil, retryAfter: nil))
  }

  @Test func streamEndingBeforeMessageStopIsInvalid() async {
    let result = await run(FakeTransport(body: messageStart + helloText))
    #expect(
      result.error as? ClaudeError == .invalidStream("the stream ended before message_stop"))
  }
}
