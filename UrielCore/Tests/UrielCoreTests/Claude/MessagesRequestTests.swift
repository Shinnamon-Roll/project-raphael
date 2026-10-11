import Foundation
import Testing
import UrielCore

func json(_ text: String) throws -> JSONValue {
  try JSONValue(json: Data(text.utf8))
}

@Suite("Messages request JSON")
struct MessagesRequestTests {
  @Test func encodesToolsSystemCacheEffortAndStream() throws {
    let schema = try json(
      #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}"#
    )
    let request = MessagesRequest(
      maxTokens: 1024,
      system: ["You are Uriel.", "Answer briefly."],
      systemCacheTTL: .oneHour,
      tools: [Tool(name: "open_app", description: "Open an installed app.", inputSchema: schema)],
      messages: [Message(role: .user, content: [.text("Open Safari")])],
      effort: .low)

    let expected = try json(
      #"""
      {
        "model": "claude-sonnet-5-5",
        "max_tokens": 1024,
        "stream": true,
        "output_config": {"effort": "low"},
        "system": [
          {"type": "text", "text": "You are Uriel."},
          {"type": "text", "text": "Answer briefly.",
           "cache_control": {"type": "ephemeral", "ttl": "1h"}}
        ],
        "tools": [{
          "name": "open_app",
          "description": "Open an installed app.",
          "input_schema": {"type": "object", "properties": {"name": {"type": "string"}},
                           "required": ["name"], "additionalProperties": false},
          "strict": true
        }],
        "tool_choice": {"type": "auto"},
        "messages": [{"role": "user", "content": [{"type": "text", "text": "Open Safari"}]}]
      }
      """#)
    #expect(try JSONValue(json: request.jsonData()) == expected)
  }

  @Test func encodesDefaultCacheThinkingAndToolResultWithoutTools() throws {
    let toolUse = ContentBlock(json: [
      "type": .string("tool_use"), "id": .string("toolu_1"), "name": .string("open_app"),
      "input": .object(["name": .string("Foo")]),
    ])
    let request = MessagesRequest(
      maxTokens: 256,
      system: ["You are Uriel."],
      messages: [
        Message(role: .user, content: [.text("Open Foo")]),
        Message(role: .assistant, content: [toolUse]),
        Message(
          role: .user,
          content: [.toolResult(toolUseID: "toolu_1", content: "No app named Foo.", isError: true)]),
      ],
      effort: .medium,
      thinking: .betweenTools)

    let expected = try json(
      #"""
      {
        "model": "claude-sonnet-5-5",
        "max_tokens": 256,
        "stream": true,
        "output_config": {"effort": "medium"},
        "thinking": {"type": "between_tools"},
        "system": [
          {"type": "text", "text": "You are Uriel.", "cache_control": {"type": "ephemeral"}}
        ],
        "messages": [
          {"role": "user", "content": [{"type": "text", "text": "Open Foo"}]},
          {"role": "assistant", "content": [
            {"type": "tool_use", "id": "toolu_1", "name": "open_app", "input": {"name": "Foo"}}
          ]},
          {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "toolu_1", "content": "No app named Foo.",
             "is_error": true}
          ]}
        ]
      }
      """#)
    #expect(try JSONValue(json: request.jsonData()) == expected)
  }
}
