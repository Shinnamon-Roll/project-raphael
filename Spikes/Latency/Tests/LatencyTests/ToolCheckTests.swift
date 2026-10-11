import Foundation
import Testing
import UrielCore

@testable import Latency

/// A tool call as Claude would send it, from its JSON input.
private func call(_ name: String, _ json: String) throws -> ToolUse {
  let input = try #require(try JSONValue(json: Data(json.utf8)).objectValue)
  return try #require(
    ContentBlock(json: [
      "type": .string("tool_use"), "id": .string("toolu_1"), "name": .string(name),
      "input": .object(input),
    ]).toolUse)
}

@Suite("Expected tool checks")
struct ToolCheckTests {
  @Test func chatWithoutAToolIsRight() {
    #expect(checkToolCalls([], expected: nil).correct)
  }

  @Test func chatThatCallsAToolIsWrong() throws {
    let check = checkToolCalls([try call("open_app", #"{"name":"Safari"}"#)], expected: nil)
    #expect(!check.correct)
    #expect(check.note == "called open_app")
  }

  @Test func openAppIgnoresCaseDiacriticsAndSpaces() throws {
    let expected = ExpectedTool.openApp(names: ["System Settings"])
    #expect(
      checkToolCalls([try call("open_app", #"{"name":" system séttings "}"#)], expected: expected)
        .correct)
    #expect(
      !checkToolCalls([try call("open_app", #"{"name":"System Preferences"}"#)], expected: expected)
        .correct)
  }

  @Test func missingWrongOrRepeatedCallsAreWrong() throws {
    let expected = ExpectedTool.openApp(names: ["Safari"])
    let safari = try call("open_app", #"{"name":"Safari"}"#)
    #expect(checkToolCalls([], expected: expected).note == "no tool call")
    #expect(!checkToolCalls([safari, safari], expected: expected).correct)
    #expect(
      !checkToolCalls(
        [try call("set_timer", #"{"duration_seconds":60,"label":""}"#)], expected: expected
      ).correct)
  }

  @Test func timerNeedsTheExactDuration() throws {
    let expected = ExpectedTool.setTimer(seconds: 600, labels: nil)
    #expect(
      checkToolCalls(
        [try call("set_timer", #"{"duration_seconds":600,"label":""}"#)], expected: expected
      ).correct)
    #expect(
      checkToolCalls(
        [try call("set_timer", #"{"duration_seconds":600.0,"label":"tea"}"#)], expected: expected
      ).correct)
    #expect(
      !checkToolCalls(
        [try call("set_timer", #"{"duration_seconds":10,"label":""}"#)], expected: expected
      ).correct)
    let fraction = checkToolCalls(
      [try call("set_timer", #"{"duration_seconds":600.5,"label":""}"#)], expected: expected)
    #expect(!fraction.correct)
    #expect(fraction.note == #"set_timer no whole number s """#)
  }

  @Test func timerLabelMustContainTheExpectedWord() throws {
    let expected = ExpectedTool.setTimer(seconds: 660, labels: ["pasta"])
    #expect(
      checkToolCalls(
        [try call("set_timer", #"{"duration_seconds":660,"label":"Pasta timer"}"#)],
        expected: expected
      ).correct)
    #expect(
      !checkToolCalls(
        [try call("set_timer", #"{"duration_seconds":660,"label":""}"#)], expected: expected
      ).correct)
  }

  @Test func fakeResultAnswersKnownToolsAndRejectsOthers() throws {
    let opened = ConversationRunner.fakeResult(for: try call("open_app", #"{"name":"Notes"}"#))
    #expect(opened.json["content"] == .string("Opened Notes."))
    #expect(opened.json["is_error"] == .bool(false))
    #expect(opened.json["tool_use_id"] == .string("toolu_1"))
    let unknown = ConversationRunner.fakeResult(for: try call("run_shell", "{}"))
    #expect(unknown.json["is_error"] == .bool(true))
  }

  @Test func everyFixtureToolIsAValidStrictSchema() throws {
    for tool in Fixtures.tools {
      let schema = try #require(tool.inputSchema.objectValue)
      #expect(schema["additionalProperties"] == .bool(false))
      let properties = try #require(schema["properties"]?.objectValue)
      guard case .array(let required) = schema["required"] else {
        Issue.record("\(tool.name) has no required list")
        continue
      }
      #expect(Set(required.compactMap(\.stringValue)) == Set(properties.keys))
      let json = String(decoding: try tool.inputSchema.jsonData(), as: UTF8.self)
      for banned in ["minimum", "maximum", "minLength", "maxLength", "multipleOf"] {
        #expect(!json.contains(#""\#(banned)""#), "\(tool.name) uses \(banned)")
      }
    }
  }
}
