import Foundation
import Testing
import UrielCore

@testable import Latency

@Suite("Thai run")
struct ThaiRunTests {
  @Test func thaiFixturesMirrorTheEnglishOnes() throws {
    let english = Fixtures.utterances
    let thai = Fixtures.thaiUtterances
    #expect(thai.count == 12)
    #expect(thai.map(\.id) == english.map(\.id))
    #expect(thai.map(\.kind) == english.map(\.kind))
    for (thai, english) in zip(thai, english) {
      #expect(thai.turns.count == english.turns.count, "\(thai.id)")
      #expect(thai.scriptedReplies.count == english.scriptedReplies.count, "\(thai.id)")
      switch (thai.expected, english.expected) {
      case (nil, nil): break
      case (.openApp(let thaiNames)?, .openApp(let englishNames)?):
        #expect(thaiNames == englishNames, "\(thai.id)")
        // The app name stays in Latin letters, as the owner says it inside Thai.
        #expect(thaiNames.allSatisfy { name in thai.turns[0].contains(name) }, "\(thai.id)")
      case (.setTimer(let thaiSeconds, let thaiLabels)?, .setTimer(let englishSeconds, let labels)?):
        #expect(thaiSeconds == englishSeconds, "\(thai.id)")
        #expect((thaiLabels == nil) == (labels == nil), "\(thai.id)")
        // The schema's example label is English, so the Thai run accepts the English label too.
        #expect(Set(labels ?? []).isSubset(of: thaiLabels ?? []), "\(thai.id)")
      default: Issue.record("\(thai.id) expects a different tool from the English fixture")
      }
      // The owner's gender is not recorded, so the owner's lines carry no gendered particle.
      for words in thai.turns {
        #expect(!["ครับ", "ค่ะ", "คะ"].contains { words.contains($0) }, "\(words)")
      }
    }
  }

  @Test func thaiRunSendsTheThaiSystemPrompt() throws {
    var runner = ConversationRunner(transport: ScriptedTransport(), key: "test")
    runner.language = .thai
    let config = try #require(Configuration.named("haiku-low"))
    let request = runner.request(config, sessionTag: "a", messages: [])
    #expect(request.system == ["Session a.", Fixtures.thaiSystemPrompt])
    #expect(Fixtures.thaiSystemPrompt != Fixtures.systemPrompt)
  }

  @Test func thaiTimerLabelMayBeThaiOrEnglish() throws {
    let expected = try #require(Fixtures.thaiUtterances.first { $0.id == "timer-2" }?.expected)
    func timer(_ label: String) throws -> ToolUse {
      try #require(
        ContentBlock(json: [
          "type": .string("tool_use"), "id": .string("toolu_1"), "name": .string("set_timer"),
          "input": .object(["duration_seconds": .number(660), "label": .string(label)]),
        ]).toolUse)
    }
    for label in ["ต้มพาสต้า", "Pasta", "pasta timer"] {
      #expect(checkToolCalls([try timer(label)], expected: expected).correct, "\(label)")
    }
    #expect(!checkToolCalls([try timer("")], expected: expected).correct)
  }

  @Test func scriptedUsageCountsThaiAsDenserThanEnglish() {
    #expect(ScriptedTransport.estimatedTokens("abcdefgh") == 2)
    // "ค่ะ" is three code points: one token at four a token, two at 1.5.
    #expect(ScriptedTransport.estimatedTokens("ค่ะค่ะ") == 4)
    #expect(ScriptedTransport.estimatedTokens("ok ค่ะ") == 2)
  }

  @Test func modesRefuseFlagsTheyDoNotTake() throws {
    for valid in [
      ["dry-run", "--language", "th", "--warm-rounds", "3", "--budget", "1.50"],
      ["run", "--language", "th"], ["tts", "--language", "th"], ["report", "results/x"], ["smoke"],
    ] {
      #expect(throws: Never.self) { try LatencyCommand.checkFlags(valid) }
    }
    for invalid in [
      ["smoke", "--language", "th"], ["report", "--language", "th"], ["tts", "--warm-rounds", "3"],
      ["run", "--languages", "th"],
    ] {
      #expect(throws: SpikeError.self) { try LatencyCommand.checkFlags(invalid) }
    }
  }

  @Test func parsesLanguageAndWarmRounds() throws {
    #expect(try LatencyCommand.language(from: ["dry-run"]) == .english)
    #expect(try LatencyCommand.language(from: ["run", "--language", "th"]) == .thai)
    #expect(try LatencyCommand.language(from: ["run", "--language", "en"]) == .english)
    #expect(throws: SpikeError.self) { try LatencyCommand.language(from: ["run", "--language"]) }
    #expect(throws: SpikeError.self) {
      try LatencyCommand.language(from: ["run", "--language", "thai"])
    }
    #expect(try LatencyCommand.warmRounds(from: ["run"]) == 10)
    #expect(
      try LatencyCommand.warmRounds(
        from: ["run", "--language", "th", "--warm-rounds", "3", "--budget", "1.50"]) == 3)
    for bad in [["--warm-rounds"], ["--warm-rounds", "0"], ["--warm-rounds", "three"]] {
      #expect(throws: SpikeError.self) { try LatencyCommand.warmRounds(from: ["run"] + bad) }
    }
  }

  /// The whole matrix in Thai against the scripted API, then its report and blind sheet.
  @Test func thaiDryRunSplitsTheRepliesAndReportsInThai() async throws {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "latency-thai-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let directory = ResultsDirectory(url: url)
    var runner = ConversationRunner(transport: ScriptedTransport(), key: "test")
    runner.language = .thai
    var matrix = Matrix(
      runner: runner, configs: Configuration.all, directory: directory, budget: Budget(cap: 3))
    #expect(try await matrix.run(warmRounds: 1) == nil)

    let turns = try directory.turns()
    #expect(!turns.isEmpty)
    #expect(turns.allSatisfy { !$0.failed && $0.toolCheck.correct })
    // The Thai splitter speaks a reply sentence by sentence, not as one block at the end.
    let reply = try #require(
      Fixtures.thaiUtterances.first { $0.id == "chat-2" }?.scriptedReplies[0])
    var splitter = SentenceSplitter()
    let sentences = splitter.append(reply) + splitter.flush()
    #expect(sentences.count == 3)
    let chat = try #require(turns.first { $0.utterance == "chat-2" && $0.turn == 1 })
    #expect(chat.requests.flatMap(\.sentences) == sentences)
    let request = try #require(chat.requests.first)
    #expect(try #require(request.firstSentence) < (request.total ?? 0))

    let info = RunInfo(
      mode: "dry-run", started: .now, budget: 3, configs: Configuration.all.map(\.id),
      warmRounds: 1, language: .thai, spent: matrix.budget.spent)
    let report = Report(name: "test", info: info, turns: turns, speech: nil)
    #expect(report.summary.contains("language `th`, 1 warm rounds"))
    let sheet = report.blindSheet.sheet
    #expect(sheet.contains("> **Owner:** เดี๋ยวนะ จริงเหรอ ทำไมต้องมีตั้งสามดวง"))
    #expect(sheet.contains("> **Uriel:** " + sentences.joined(separator: " ")))
  }
}
