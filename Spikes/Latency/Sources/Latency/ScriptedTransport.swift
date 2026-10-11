import Foundation
import UrielCore

/// A fake Claude API for `dry-run` and the tests: no key, no network, no cost.
///
/// It answers each utterance with its scripted reply, calls the expected tool, and streams the
/// reply as SSE in the API's shape. It reports plausible usage, simulating the prompt cache, so
/// the dry run's cost is an estimate of a real run's. Like the real API, it rejects history whose
/// thinking blocks lost their signature.
struct ScriptedTransport: HTTPTransport {
  /// The pause after each event, so times are not all zero.
  var eventDelay: Duration = .zero
  private let cache = PromptCache()

  init(eventDelay: Duration = .zero) {
    self.eventDelay = eventDelay
  }

  static let signature = "dry-run-signature"

  func send(_ request: URLRequest) async throws -> HTTPStreamResponse {
    if request.url?.path().hasPrefix("/v1/models/") == true {
      return response(
        status: 200,
        lines: [#"{"capabilities":{"thinking":{"types":{"disabled":{"supported":true}}}}}"#])
    }
    let body = try JSONValue(json: request.httpBody ?? Data())
    let model = body["model"]?.stringValue ?? ""
    let thinking = body["thinking"]?["type"]?.stringValue
    let effort = body["output_config"]?["effort"]?.stringValue
    guard case .array(let messages) = body["messages"] else { throw URLError(.badURL) }

    let adaptive = thinking == nil
    for message in messages where message["role"]?.stringValue == "assistant" {
      guard case .array(let blocks) = message["content"] else { continue }
      let signed = blocks.first?["signature"]?.stringValue == Self.signature
      if adaptive, !signed {
        return response(
          status: 400,
          lines: [
            #"{"type":"error","error":{"type":"invalid_request_error","message":"dry run: a thinking block came back changed"}}"#
          ])
      }
    }

    let userTexts = messages.filter { message in
      message["role"]?.stringValue == "user"
        && Self.blocks(of: message).contains { $0["type"]?.stringValue == "text" }
    }
    let firstWords = userTexts.first.flatMap { Self.blocks(of: $0).first?["text"]?.stringValue }
    let utterance = Fixtures.utterances.first { $0.turns.first == firstWords }
    let afterTool = Self.blocks(of: messages.last).contains {
      $0["type"]?.stringValue == "tool_result"
    }

    var text = ""
    var toolInput: JSONValue?
    var toolName = ""
    switch (utterance?.expected, afterTool) {
    case (.openApp(let names)?, false):
      toolName = "open_app"
      toolInput = .object(["name": .string(names.first ?? "")])
    case (.setTimer(let seconds, let label)?, false):
      toolName = "set_timer"
      toolInput = .object([
        "duration_seconds": .number(Double(seconds)), "label": .string(label ?? ""),
      ])
    default:
      let replies = utterance?.scriptedReplies ?? []
      let turn = afterTool ? 0 : userTexts.count - 1
      text = replies.indices.contains(turn) ? replies[turn] : "This is a dry run."
    }

    // Usage at about four characters a token, plus a guess for the tool-use system prompt.
    let system = Self.blocks(of: body["system"]).compactMap { $0["text"]?.stringValue }.joined()
    let tools = (try? body["tools"]?.jsonData().count) ?? 0
    let prefixTokens = (system.count + tools) / 4 + 300
    let hit = await cache.contains(model + system)
    let inputTokens = ((try? JSONValue.array(messages).jsonData().count) ?? 0) / 4
    let toolJSON = (try? toolInput?.jsonData()).map { String(decoding: $0, as: UTF8.self) } ?? ""
    let thinkingTokens = adaptive ? (effort == "low" ? 20 : 80) : 0
    let outputTokens = (text.count + toolJSON.count) / 4 + thinkingTokens + 5

    var events: [(String, JSONValue)] = [
      (
        "message_start",
        .object([
          "type": .string("message_start"),
          "message": .object([
            "id": .string("msg_dry_run"), "type": .string("message"), "role": .string("assistant"),
            "model": .string(model), "content": .array([]),
            "usage": .object([
              "input_tokens": .number(Double(inputTokens)),
              "cache_creation_input_tokens": .number(Double(hit ? 0 : prefixTokens)),
              "cache_read_input_tokens": .number(Double(hit ? prefixTokens : 0)),
              "output_tokens": .number(1),
            ]),
          ]),
        ])
      )
    ]
    var index = 0
    func block(_ start: JSONValue, deltas: [JSONValue]) {
      events.append(
        Self.event(
          "content_block_start", ["index": .number(Double(index)), "content_block": start]))
      for delta in deltas {
        events.append(
          Self.event("content_block_delta", ["index": .number(Double(index)), "delta": delta]))
      }
      events.append(Self.event("content_block_stop", ["index": .number(Double(index))]))
      index += 1
    }
    if adaptive {
      // Thinking is shown as omitted by default, so the block's text is empty.
      block(
        .object(["type": .string("thinking"), "thinking": .string("")]),
        deltas: [
          .object(["type": .string("signature_delta"), "signature": .string(Self.signature)])
        ])
    }
    if !text.isEmpty {
      let words = text.split(separator: " ", omittingEmptySubsequences: false)
      let pieces = stride(from: 0, to: words.count, by: 3).map { start in
        words[start..<min(start + 3, words.count)].joined(separator: " ")
          + (start + 3 < words.count ? " " : "")
      }
      block(
        .object(["type": .string("text"), "text": .string("")]),
        deltas: pieces.map { .object(["type": .string("text_delta"), "text": .string($0)]) })
    }
    if toolInput != nil {
      let middle = toolJSON.index(toolJSON.startIndex, offsetBy: toolJSON.count / 2)
      block(
        .object([
          "type": .string("tool_use"), "id": .string("toolu_dry_run_\(userTexts.count)"),
          "name": .string(toolName), "input": .object([:]),
        ]),
        deltas: [String(toolJSON[..<middle]), String(toolJSON[middle...])].map {
          .object(["type": .string("input_json_delta"), "partial_json": .string($0)])
        })
    }
    events.append(
      Self.event(
        "message_delta",
        [
          "delta": .object(["stop_reason": .string(toolInput == nil ? "end_turn" : "tool_use")]),
          "usage": .object(["output_tokens": .number(Double(outputTokens))]),
        ]))
    events.append(Self.event("message_stop", [:]))

    let lines = try events.flatMap { name, data in
      ["event: \(name)", "data: \(String(decoding: try data.jsonData(), as: UTF8.self))", ""]
    }
    return response(status: 200, lines: lines)
  }

  private func response(status: Int, lines: [String]) -> HTTPStreamResponse {
    let delay = eventDelay
    return HTTPStreamResponse(
      statusCode: status, headers: [:],
      lines: AsyncThrowingStream { continuation in
        let task = Task {
          for line in lines {
            if line.isEmpty, delay > .zero { try? await Task.sleep(for: delay) }
            continuation.yield(line)
          }
          continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
      })
  }

  private static func event(_ type: String, _ fields: [String: JSONValue]) -> (String, JSONValue) {
    var data = fields
    data["type"] = .string(type)
    return (type, .object(data))
  }

  private static func blocks(of value: JSONValue?) -> [JSONValue] {
    if case .array(let blocks) = value?["content"] ?? value { blocks } else { [] }
  }
}

/// The prompt prefixes seen so far, standing in for the API's prompt cache.
private actor PromptCache {
  private var seen: Set<String> = []

  /// Whether `prefix` was seen before; it is remembered either way.
  func contains(_ prefix: String) -> Bool { !seen.insert(prefix).inserted }
}
