import Foundation

/// Supplies the Anthropic API key. ``KeychainAPIKeyStore`` is the real one.
///
/// The key is a secret: never log it, and never read it from the environment.
public protocol APIKeyProvider: Sendable {
  func apiKey() async throws -> String
}

/// The HTTP layer under ``ClaudeClient``, so tests can feed a canned response without a network.
public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> HTTPStreamResponse
}

/// An HTTP response whose body arrives line by line.
public struct HTTPStreamResponse: Sendable {
  public var statusCode: Int
  /// Header values by lowercased name.
  public var headers: [String: String]
  /// The body, one line at a time, without line endings; empty lines are kept.
  public var lines: AsyncThrowingStream<String, any Error>

  public init(
    statusCode: Int, headers: [String: String], lines: AsyncThrowingStream<String, any Error>
  ) {
    self.statusCode = statusCode
    self.headers = headers
    self.lines = lines
  }
}

/// The real transport, on `URLSession.bytes(for:)`.
public struct URLSessionTransport: HTTPTransport {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func send(_ request: URLRequest) async throws -> HTTPStreamResponse {
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    var headers: [String: String] = [:]
    for case (let name as String, let value as String) in response.allHeaderFields {
      headers[name.lowercased()] = value
    }
    return HTTPStreamResponse(
      statusCode: response.statusCode, headers: headers,
      lines: ServerSentEventParser.lines(from: bytes))
  }
}

/// A failure the Claude client reports. It never retries; the turn loop decides (Phase 1 step 5).
public enum ClaudeError: Error, Sendable, Hashable {
  /// A non-2xx response. `type` and `message` come from the error body when it has them, and
  /// `retryAfter` from the `retry-after` header.
  case http(status: Int, type: String?, message: String?, retryAfter: Duration?)
  /// An `error` event inside a stream that began with HTTP 200, such as `overloaded_error`.
  case stream(type: String, message: String)
  /// The response did not follow the streaming protocol.
  case invalidStream(String)
}

/// Token counts of one response; the latency spike uses them for cost.
public struct Usage: Sendable, Hashable {
  /// Input tokens after the last cache breakpoint, which were neither read from nor written to it.
  public var inputTokens: Int
  public var outputTokens: Int
  public var cacheCreationInputTokens: Int
  public var cacheReadInputTokens: Int

  public init(
    inputTokens: Int = 0, outputTokens: Int = 0, cacheCreationInputTokens: Int = 0,
    cacheReadInputTokens: Int = 0
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cacheCreationInputTokens = cacheCreationInputTokens
    self.cacheReadInputTokens = cacheReadInputTokens
  }

  /// Counts in `message_delta` are cumulative, so each one present replaces the earlier value.
  mutating func update(from usage: JSONValue?) {
    inputTokens = usage?["input_tokens"]?.intValue ?? inputTokens
    outputTokens = usage?["output_tokens"]?.intValue ?? outputTokens
    cacheCreationInputTokens =
      usage?["cache_creation_input_tokens"]?.intValue ?? cacheCreationInputTokens
    cacheReadInputTokens = usage?["cache_read_input_tokens"]?.intValue ?? cacheReadInputTokens
  }
}

/// One complete response from Claude.
public struct ClaudeResponse: Sendable, Hashable {
  /// Every block in the order received, including thinking blocks; read them by type.
  public var content: [ContentBlock]
  /// For example `end_turn`, `tool_use`, `max_tokens` or `refusal`.
  public var stopReason: String?
  public var usage: Usage

  /// The assistant message to append to the conversation, unchanged (ADR 0008).
  public var message: Message { Message(role: .assistant, content: content) }
}

/// What ``ClaudeClient/stream(_:)`` yields.
public enum ClaudeStreamEvent: Sendable, Hashable {
  /// Text from a `text` block, as it arrives.
  case textDelta(String)
  /// The finished response. It is always the last event.
  case completed(ClaudeResponse)
}

/// A client for the Claude Messages API with streaming (ADR 0002).
public struct ClaudeClient: Sendable {
  static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

  private let keyProvider: any APIKeyProvider
  private let transport: any HTTPTransport

  public init(keyProvider: any APIKeyProvider, transport: any HTTPTransport = URLSessionTransport())
  {
    self.keyProvider = keyProvider
    self.transport = transport
  }

  /// Sends `request` and streams the reply: each piece of text as it arrives, then the response.
  ///
  /// The stream throws a ``ClaudeError``, a `URLError` or the key provider's error. Cancelling
  /// the consuming task cancels the request.
  public func stream(_ request: MessagesRequest) -> AsyncThrowingStream<
    ClaudeStreamEvent, any Error
  > {
    let (events, continuation) = AsyncThrowingStream<ClaudeStreamEvent, any Error>.makeStream()
    let task = Task {
      do {
        try await run(request) { continuation.yield($0) }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { _ in task.cancel() }
    return events
  }

  private func run(_ request: MessagesRequest, yield: (ClaudeStreamEvent) -> Void) async throws {
    let key = try await keyProvider.apiKey()
    var urlRequest = URLRequest(url: Self.endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
    urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
    urlRequest.httpBody = try request.jsonData()

    let response = try await transport.send(urlRequest)
    guard (200..<300).contains(response.statusCode) else {
      throw await Self.httpError(from: response)
    }
    var parser = ServerSentEventParser()
    var accumulator = ResponseAccumulator()
    for try await line in response.lines {
      guard let event = parser.parse(line: line) else { continue }
      if let text = try accumulator.apply(event) { yield(.textDelta(text)) }
      if let finished = accumulator.response {
        yield(.completed(finished))
        return
      }
    }
    throw ClaudeError.invalidStream("the stream ended before message_stop")
  }

  private static func httpError(from response: HTTPStreamResponse) async -> ClaudeError {
    var body = ""
    do {
      for try await line in response.lines {
        body += line + "\n"
        if body.utf8.count > 65_536 { break }  // An error body is small; this is not one.
      }
    } catch {
      // The status is the error; a body cut short only loses its message.
    }
    let error = (try? JSONValue(json: Data(body.utf8)))?["error"]
    return .http(
      status: response.statusCode,
      type: error?["type"]?.stringValue,
      message: error?["message"]?.stringValue,
      retryAfter: response.headers["retry-after"].flatMap(Double.init).map { .seconds($0) })
  }
}

/// Builds a ``ClaudeResponse`` from stream events, keeping each block as the JSON it arrived as.
struct ResponseAccumulator {
  private var blocks: [[String: JSONValue]] = []
  private var partialInputs: [Int: String] = [:]
  private var stopReason: String?
  private var usage = Usage()
  private(set) var response: ClaudeResponse?

  /// Applies one event and returns the text it adds to a `text` block, if any.
  mutating func apply(_ event: ServerSentEvent) throws -> String? {
    switch event.event ?? "" {
    case "message_start":
      usage.update(from: try Self.payload(of: event)["message"]?["usage"])
    case "content_block_start":
      let data = try Self.payload(of: event)
      guard data["index"]?.intValue == blocks.count,
        let block = data["content_block"]?.objectValue
      else { throw ClaudeError.invalidStream("content_block_start out of order") }
      blocks.append(block)
    case "content_block_delta":
      return try applyDelta(Self.payload(of: event))
    case "content_block_stop":
      let index = try blockIndex(in: Self.payload(of: event))
      if let input = partialInputs.removeValue(forKey: index) {
        blocks[index]["input"] = try Self.toolInput(input)
      }
    case "message_delta":
      let data = try Self.payload(of: event)
      stopReason = data["delta"]?["stop_reason"]?.stringValue ?? stopReason
      usage.update(from: data["usage"])
    case "message_stop":
      response = ClaudeResponse(
        content: blocks.map(ContentBlock.init(json:)), stopReason: stopReason, usage: usage)
    case "error":
      let error = try Self.payload(of: event)["error"]
      throw ClaudeError.stream(
        type: error?["type"]?.stringValue ?? "unknown",
        message: error?["message"]?.stringValue ?? "")
    default:
      break  // `ping`, and event types added to the API later.
    }
    return nil
  }

  private mutating func applyDelta(_ data: JSONValue) throws -> String? {
    let index = try blockIndex(in: data)
    let delta = data["delta"]
    switch delta?["type"]?.stringValue ?? "" {
    case "text_delta":
      let text = delta?["text"]?.stringValue ?? ""
      append(text, to: "text", at: index)
      return text.isEmpty ? nil : text
    case "thinking_delta":
      append(delta?["thinking"]?.stringValue ?? "", to: "thinking", at: index)
    case "signature_delta":
      blocks[index]["signature"] = delta?["signature"]
    case "input_json_delta":
      partialInputs[index, default: ""] += delta?["partial_json"]?.stringValue ?? ""
    default:
      // shortcut: other delta types (citations, server tools) are dropped, as the SDKs do; add
      // each one when Uriel turns on the feature that streams it.
      break
    }
    return nil
  }

  private mutating func append(_ piece: String, to field: String, at index: Int) {
    blocks[index][field] = .string((blocks[index][field]?.stringValue ?? "") + piece)
  }

  private func blockIndex(in data: JSONValue) throws -> Int {
    guard let index = data["index"]?.intValue, blocks.indices.contains(index) else {
      throw ClaudeError.invalidStream("a content block event names an unknown index")
    }
    return index
  }

  /// Tool input arrives as pieces of JSON text that are valid only once joined.
  private static func toolInput(_ json: String) throws -> JSONValue {
    if json.isEmpty { return .object([:]) }
    do {
      return try JSONValue(json: Data(json.utf8))
    } catch {
      throw ClaudeError.invalidStream("tool input is not valid JSON")
    }
  }

  private static func payload(of event: ServerSentEvent) throws -> JSONValue {
    do {
      return try JSONValue(json: Data(event.data.utf8))
    } catch {
      throw ClaudeError.invalidStream("\(event.event ?? "an event") data is not JSON")
    }
  }
}
