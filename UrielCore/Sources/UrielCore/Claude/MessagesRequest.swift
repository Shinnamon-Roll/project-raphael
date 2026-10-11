import Foundation

/// The Claude model IDs Uriel uses (ADR 0002).
public enum ClaudeModel {
  /// The chat model. Sonnet 5.5 is the proposal; the latency spike (Phase 0 step 6) settles it.
  public static let chat = "claude-sonnet-5-5"
}

/// How much effort Claude spends on an answer, sent as `output_config.effort`.
public enum Effort: String, Sendable, Hashable {
  case low
  case medium
  case high
  case xhigh
  case max
}

/// The `thinking` setting. Which one Uriel uses is measured by the latency spike (Phase 0 step 6).
public enum Thinking: String, Sendable, Hashable {
  case adaptive
  /// Sonnet 5.5 only, at effort `high` or below: thinking off except between tool calls.
  case betweenTools = "between_tools"
  /// Accepted by Haiku 5.5 at effort `high` or below; Sonnet 5.5 and Opus 5.5 answer 400.
  case disabled
}

/// How long the cached system prompt lives.
public enum CacheTTL: Sendable, Hashable {
  case fiveMinutes
  case oneHour

  var cacheControl: JSONValue {
    switch self {
    case .fiveMinutes: .object(["type": .string("ephemeral")])
    case .oneHour: .object(["type": .string("ephemeral"), "ttl": .string("1h")])
    }
  }
}

/// A tool Claude may call. Every tool is sent with `strict: true` (ADR 0005).
public struct Tool: Sendable, Hashable {
  public var name: String
  public var description: String
  /// The JSON schema of the tool's input. Strict tools cannot use `minimum` or `maximum`.
  public var inputSchema: JSONValue

  public init(name: String, description: String, inputSchema: JSONValue) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
  }
}

/// One message of a conversation, in the shape the Messages API takes.
public struct Message: Sendable, Hashable {
  /// Who wrote the message.
  public enum Role: String, Sendable, Hashable {
    case user
    case assistant
  }

  public var role: Role
  public var content: [ContentBlock]

  public init(role: Role, content: [ContentBlock]) {
    self.role = role
    self.content = content
  }

  var json: JSONValue {
    .object(["role": .string(role.rawValue), "content": .array(content.map { .object($0.json) })])
  }
}

/// One content block, stored as the JSON object the API sent or will receive.
///
/// Assistant content goes back to the API exactly as received (ADR 0008): thinking blocks keep
/// their signatures, and block types and fields Uriel does not model are kept, never dropped.
public struct ContentBlock: Sendable, Hashable {
  public let json: [String: JSONValue]

  public init(json: [String: JSONValue]) {
    self.json = json
  }

  /// A `text` block.
  public static func text(_ text: String) -> ContentBlock {
    ContentBlock(json: ["type": .string("text"), "text": .string(text)])
  }

  /// A `tool_result` block answering the `tool_use` block with `toolUseID`.
  public static func toolResult(toolUseID: String, content: String, isError: Bool) -> ContentBlock {
    ContentBlock(json: [
      "type": .string("tool_result"),
      "tool_use_id": .string(toolUseID),
      "content": .string(content),
      "is_error": .bool(isError),
    ])
  }

  /// The block's `type`, such as `text`, `tool_use`, `thinking` or `redacted_thinking`.
  public var type: String? { json["type"]?.stringValue }

  /// The text, when this is a `text` block.
  public var text: String? { type == "text" ? json["text"]?.stringValue : nil }

  /// The call, when this is a `tool_use` block.
  public var toolUse: ToolUse? {
    guard type == "tool_use", let id = json["id"]?.stringValue,
      let name = json["name"]?.stringValue, let input = json["input"]?.objectValue
    else { return nil }
    return ToolUse(id: id, name: name, input: input)
  }
}

/// A tool call from Claude. Its arguments are unchecked model output; validate them before use.
public struct ToolUse: Sendable, Hashable {
  public let id: String
  public let name: String
  public let input: [String: JSONValue]
}

/// A streaming Messages API request (`POST /v1/messages`).
///
/// It always sends `stream: true`, `strict: true` on every tool, `tool_choice: auto` (forced tool
/// choice is a 400 on Sonnet 5.5 and Opus 5.5, so it cannot be expressed), an explicit effort, and
/// `cache_control` on the last system block.
public struct MessagesRequest: Sendable, Hashable {
  public var model: String
  public var maxTokens: Int
  /// The system prompt as text blocks. Keep it byte-stable across a conversation (ADR 0008).
  public var system: [String]
  public var systemCacheTTL: CacheTTL
  public var tools: [Tool]
  public var messages: [Message]
  public var effort: Effort
  /// `nil` sends no `thinking` field, so the model's default applies.
  public var thinking: Thinking?

  public init(
    model: String = ClaudeModel.chat,
    maxTokens: Int,
    system: [String],
    systemCacheTTL: CacheTTL = .fiveMinutes,
    tools: [Tool] = [],
    messages: [Message],
    effort: Effort,
    thinking: Thinking? = nil
  ) {
    self.model = model
    self.maxTokens = maxTokens
    self.system = system
    self.systemCacheTTL = systemCacheTTL
    self.tools = tools
    self.messages = messages
    self.effort = effort
    self.thinking = thinking
  }

  /// The request body. Keys are sorted, so an unchanged prefix encodes to unchanged bytes.
  public func jsonData() throws -> Data {
    var body: [String: JSONValue] = [
      "model": .string(model),
      "max_tokens": .number(Double(maxTokens)),
      "stream": .bool(true),
      "messages": .array(messages.map(\.json)),
      "output_config": .object(["effort": .string(effort.rawValue)]),
    ]
    if !system.isEmpty {
      body["system"] = .array(
        system.indices.map { index in
          var block: [String: JSONValue] = [
            "type": .string("text"), "text": .string(system[index]),
          ]
          if index == system.indices.last { block["cache_control"] = systemCacheTTL.cacheControl }
          return .object(block)
        })
    }
    if !tools.isEmpty {
      body["tools"] = .array(
        tools.map { tool in
          .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "input_schema": tool.inputSchema,
            "strict": .bool(true),
          ])
        })
      body["tool_choice"] = .object(["type": .string("auto")])
    }
    if let thinking {
      body["thinking"] = .object(["type": .string(thinking.rawValue)])
    }
    return try JSONValue.object(body).jsonData()
  }
}
