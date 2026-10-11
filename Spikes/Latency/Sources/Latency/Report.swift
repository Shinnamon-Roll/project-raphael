import Foundation

/// Turns a run's raw results into the summary tables for `docs/spikes/latency.md` and the blind
/// rating sheet.
struct Report {
  let name: String
  let info: RunInfo
  let turns: [TurnRecord]
  /// The newest text-to-speech measure, when `tts` has run.
  let speech: SpeechStartResult?

  /// The owner's target: at most 1.5 s at p50 from the end of speech to the first spoken word.
  static let ownerTarget = 1.5
  /// The end-of-utterance silence timer, which runs before the request (docs/plan.md, Phase 1
  /// step 3).
  static let endOfUtteranceTimer = 0.8
  /// What is left of the owner's target for the API and the voice to start.
  static let apiAndSpeechTarget = ownerTarget - endOfUtteranceTimer

  /// The fixed seed of the blind sheet, so the same results always give the same labels.
  static let blindSeed: UInt64 = 20_261_011

  private var configs: [Configuration] { info.configs.compactMap(Configuration.named) }

  /// Turns of the cold and warm phases, the ones the statistics use.
  private func measured(_ config: Configuration, _ group: Group, _ phase: Phase) -> [TurnRecord] {
    turns.filter {
      $0.config == config.id && $0.phase == phase && Group(kind: $0.kind) == group
    }
  }

  /// Chat turns, or turns that should call a tool.
  enum Group: String, CaseIterable {
    case chat
    case tool

    init(kind: Utterance.Kind) {
      self = kind == .chat ? .chat : .tool
    }
  }

  // MARK: - Summary

  var summary: String {
    var lines: [String] = []
    let requests = turns.flatMap(\.requests)
    let failed = requests.filter { $0.error != nil }.count
    lines += [
      "# Latency spike results (`\(name)`)",
      "",
      "Mode `\(info.mode)`, language `\((info.language ?? .english).rawValue)`, "
        + "\(info.warmRounds) warm rounds, started "
        + "\(info.started.formatted(date: .abbreviated, time: .shortened)). "
        + "\(requests.count) requests in \(turns.count) turns, \(failed) failed. "
        + String(format: "Spent $%.4f of the $%.2f budget.", info.spent, info.budget),
    ]
    if let stop = info.stop { lines.append("**Stopped early:** \(stop).") }
    lines += ["", "Configurations:", ""]
    lines += configs.map { "- `\($0.id)`: \($0.label)" }
    lines += info.skipped.sorted(by: { $0.key < $1.key }).map {
      "- `\($0.key)`: skipped. \($0.value)"
    }
    lines += [
      "",
      "Times are p50 / p95 in milliseconds. A turn runs from the end of the owner's utterance to "
        + "the first complete sentence, across the tool call when there is one. Cold: the "
        + "conversation's first request missed the prompt cache (a fresh session tag); its later "
        + "requests read what it wrote. Warm: the prefix was cached seconds before. The prime "
        + "requests are left out. Connections are kept alive, so no time is spent on TLS setup "
        + "after the first request.",
      "",
    ]
    lines += turnTable() + [""] + requestTable() + [""] + costTable() + [""] + toolTable()
    lines += [""] + stopReasonTable() + [""] + speechSection() + [""] + firstRequests()
    lines += [""] + failures()
    return lines.joined(separator: "\n") + "\n"
  }

  private func turnTable() -> [String] {
    let ttsP50 = speech.flatMap { percentile(50, of: $0.warm) }
    var lines = [
      "## First sentence of a turn",
      "",
      "The owner's target is at most \(Self.seconds(Self.ownerTarget)) at p50 from the end of "
        + "speech to the first spoken word. The end-of-utterance silence timer (about "
        + "\(Self.seconds(Self.endOfUtteranceTimer)), docs/plan.md Phase 1 step 3) runs before "
        + "the request, so the API and the voice have \(Self.seconds(Self.apiAndSpeechTarget)) "
        + "left; the transcriber's finalize also comes out of that. The last columns add the "
        + "text-to-speech start p50 (\(milliseconds(ttsP50))); adding two p50s is an estimate, "
        + "not a measured p50.",
      "",
      "| Configuration | Kind | Phase | Turns | p50 | p95 | + TTS p50 | API + TTS ≤ "
        + "\(Self.seconds(Self.apiAndSpeechTarget)) |",
      "|---|---|---|---|---|---|---|---|",
    ]
    for config in configs {
      for group in Group.allCases {
        for phase in [Phase.warm, .cold] {
          let values = measured(config, group, phase).compactMap(\.firstSentence)
          let p50 = percentile(50, of: values)
          let spoken = p50.map { $0 + (ttsP50 ?? 0) }
          let verdict = spoken.map { $0 <= Self.apiAndSpeechTarget ? "yes" : "no" } ?? "–"
          lines.append(
            "| `\(config.id)` | \(group.rawValue) | \(phase.rawValue) | \(values.count) | "
              + "\(milliseconds(p50)) | \(milliseconds(percentile(95, of: values))) | "
              + "\(ttsP50 == nil ? "–" : milliseconds(spoken)) | \(ttsP50 == nil ? "–" : verdict) |"
          )
        }
      }
    }
    return lines
  }

  private func requestTable() -> [String] {
    func both(_ values: [Double]) -> String {
      "\(milliseconds(percentile(50, of: values))) / \(milliseconds(percentile(95, of: values)))"
    }
    var lines = [
      "## Per request",
      "",
      "From the start of each request. The gap is between each later sentence and the one before.",
      "",
      "| Configuration | Kind | Phase | Requests | First text | First sentence | Sentence gap | Total |",
      "|---|---|---|---|---|---|---|---|",
    ]
    for config in configs {
      for group in Group.allCases {
        for phase in [Phase.warm, .cold] {
          let requests = measured(config, group, phase).flatMap(\.requests).filter {
            $0.error == nil
          }
          lines.append(
            "| `\(config.id)` | \(group.rawValue) | \(phase.rawValue) | \(requests.count) | "
              + "\(both(requests.compactMap(\.firstTextDelta))) | "
              + "\(both(requests.compactMap(\.firstSentence))) | "
              + "\(both(requests.flatMap(\.sentenceGaps))) | \(both(requests.compactMap(\.total))) |"
          )
        }
      }
    }
    return lines
  }

  private func costTable() -> [String] {
    var lines = [
      "## Cost and cache",
      "",
      "Cost from each response's usage at the prices in `CLAUDE.md`. Every warm request should "
        + "read the cache, and every cold conversation's first request should write it.",
      "",
      "| Configuration | Requests | Failed | Cost | Per chat turn | Per tool turn | Warm requests "
        + "reading the cache | Cold first requests writing it |",
      "|---|---|---|---|---|---|---|---|",
    ]
    var warnings: [String] = []
    for config in configs {
      let all = turns.filter { $0.config == config.id }
      let requests = all.flatMap(\.requests)
      func perTurn(_ group: Group) -> String {
        let costs = all.filter {
          ($0.phase == .cold || $0.phase == .warm) && Group(kind: $0.kind) == group
        }.map {
          $0.requests.reduce(0) { $0 + $1.cost }
        }
        return costs.isEmpty
          ? "–" : String(format: "$%.5f", costs.reduce(0, +) / Double(costs.count))
      }
      let warm = all.filter { $0.phase == .warm }.flatMap(\.requests).compactMap(\.tokens)
      let warmReads = warm.filter { $0.cacheRead > 0 }.count
      let cold = all.filter { $0.phase == .cold && $0.turn == 1 }.compactMap(
        \.requests.first?.tokens)
      let coldWrites = cold.filter { $0.cacheWrite > 0 && $0.cacheRead == 0 }.count
      if !warm.isEmpty, warmReads == 0 {
        warnings.append(
          "**Warning:** no warm request of `\(config.id)` read the cache. The prefix is under the "
            + "512-token minimum, or something in it changes between requests.")
      }
      lines.append(
        "| `\(config.id)` | \(requests.count) | \(requests.filter { $0.error != nil }.count) | "
          + String(format: "$%.4f", requests.reduce(0) { $0 + $1.cost }) + " | "
          + "\(perTurn(.chat)) | \(perTurn(.tool)) | \(warmReads) of \(warm.count) | "
          + "\(coldWrites) of \(cold.count) |")
    }
    return lines + (warnings.isEmpty ? [] : [""] + warnings)
  }

  private func toolTable() -> [String] {
    var lines = [
      "## Tool calls",
      "",
      "Right means the expected tool, called once, with the expected arguments. Chat turns, "
        + "follow-ups included, should call no tool.",
      "",
      "| Configuration | open_app right | set_timer right | Chat with no tool | Wrong calls |",
      "|---|---|---|---|---|",
    ]
    for config in configs {
      let checked = turns.filter {
        $0.config == config.id && ($0.phase == .cold || $0.phase == .warm) && !$0.failed
      }
      func right(_ kind: Utterance.Kind) -> String {
        let of = checked.filter { $0.kind == kind }
        return "\(of.filter(\.toolCheck.correct).count) of \(of.count)"
      }
      let wrong = Dictionary(grouping: checked.filter { !$0.toolCheck.correct }) {
        "\($0.utterance) → \($0.toolCheck.note)"
      }
      let notes = wrong.keys.sorted().map { "\($0) (×\(wrong[$0]?.count ?? 0))" }
      lines.append(
        "| `\(config.id)` | \(right(.openApp)) | \(right(.timer)) | \(right(.chat)) | "
          + "\(notes.isEmpty ? "none" : notes.joined(separator: "; ")) |")
    }
    return lines
  }

  private func stopReasonTable() -> [String] {
    let known = ["end_turn", "tool_use", "max_tokens", "refusal"]
    var lines = [
      "## Stop reasons", "", "| Configuration | " + known.joined(separator: " | ") + " | other |",
      "|---|---|---|---|---|---|",
    ]
    for config in configs {
      let reasons = turns.filter { $0.config == config.id }.flatMap(\.requests).compactMap(
        \.stopReason)
      let counts = known.map { reason in reasons.filter { $0 == reason }.count.description }
      let other = reasons.filter { !known.contains($0) }.count
      lines.append("| `\(config.id)` | " + counts.joined(separator: " | ") + " | \(other) |")
    }
    return lines
  }

  private func speechSection() -> [String] {
    guard let speech else {
      return ["## Text-to-speech start", "", "No `tts` results yet: run `latency tts`."]
    }
    return [
      "## Text-to-speech start",
      "",
      "From `speak` to `didStart`, silent (volume 0), voice \(speech.voiceName) "
        + "(`\(speech.voiceIdentifier)`, \(speech.quality)), measured \(speech.date.formatted()).",
      "",
      "| First utterance (cold synthesizer) | Later sentences | p50 | p95 |",
      "|---|---|---|---|",
      "| \(milliseconds(speech.cold)) | \(speech.warm.count) | "
        + "\(milliseconds(percentile(50, of: speech.warm))) | "
        + "\(milliseconds(percentile(95, of: speech.warm))) |",
    ]
  }

  /// The first request of the run on each model may include connection setup and the one-time
  /// compilation of the strict tool schemas.
  private func firstRequests() -> [String] {
    var lines = ["## First request per model", ""]
    var seen: Set<String> = []
    for turn in turns {
      guard let config = Configuration.named(turn.config), seen.insert(config.model).inserted,
        let request = turn.requests.first
      else { continue }
      lines.append(
        "- \(config.model) (`\(turn.config)`, \(turn.phase.rawValue) \(turn.utterance)): first text "
          + "\(milliseconds(request.firstTextDelta)), total \(milliseconds(request.total)). It may "
          + "include TLS setup and compiling the strict tool schemas.")
    }
    return lines
  }

  private func failures() -> [String] {
    let failed = turns.filter(\.failed)
    guard !failed.isEmpty else { return ["## Failures", "", "None."] }
    return ["## Failures", ""]
      + failed.map { turn in
        "- `\(turn.config)` \(turn.phase.rawValue) r\(turn.round) \(turn.utterance) turn \(turn.turn): "
          + (turn.requests.compactMap(\.error).last ?? "")
      }
  }

  // MARK: - Blind rating sheet

  /// For each chat utterance, the configurations in the order of their labels A, B, C...,
  /// shuffled with `seed`.
  static func blindOrder(
    configs: [String], utterances: [String], seed: UInt64
  ) -> [String: [String]] {
    var generator = SeededGenerator(seed: seed)
    var order: [String: [String]] = [:]
    for utterance in utterances { order[utterance] = configs.shuffled(using: &generator) }
    return order
  }

  /// The sheet the owner rates, and the key that names the configuration behind each label.
  var blindSheet: (sheet: String, key: String) {
    let chats = (info.language ?? .english).utterances.filter { $0.kind == .chat }
    let order = Self.blindOrder(
      configs: configs.map(\.id), utterances: chats.map(\.id), seed: Self.blindSeed)
    var sheet = [
      "# Blind rating: does Uriel sound like Claude?",
      "",
      "Each conversation below was answered by every configuration, in shuffled order. Rate each "
        + "answer from 1 (nothing like chatting with Claude) to 5 (just like it), as if you heard "
        + "it spoken. The key is in `blind-key.md`; open it only after rating.",
    ]
    var key = [
      "# Blind rating key", "", "Seed \(Self.blindSeed).", "",
      "| Conversation | " + configs.indices.map { Self.label($0) }.joined(separator: " | ") + " |",
      "|---|" + String(repeating: "---|", count: configs.count),
    ]
    for chat in chats {
      let ids = order[chat.id] ?? []
      sheet += ["", "## \(chat.id)", ""]
      for (index, id) in ids.enumerated() {
        sheet += ["### \(Self.label(index))", ""]
        let answer = Self.ratedConversation(
          turns.filter { $0.config == id && $0.utterance == chat.id })
        let quote = chat.turns.enumerated().flatMap { turn, words in
          ["> **Owner:** \(words)", "> **Uriel:** \(answer[turn + 1] ?? "(no answer)")"]
        }
        sheet += [quote.joined(separator: "\n>\n"), "", "Rating (1–5): ____", ""]
      }
      key.append("| \(chat.id) | " + ids.map { "`\($0)`" }.joined(separator: " | ") + " |")
    }
    return (sheet.joined(separator: "\n") + "\n", key.joined(separator: "\n") + "\n")
  }

  /// The spoken answer of each turn of the first complete warm conversation, by turn number.
  private static func ratedConversation(_ turns: [TurnRecord]) -> [Int: String] {
    let warm = turns.filter { $0.phase == .warm }
    let rounds = Set(warm.map(\.round)).sorted()
    let round =
      rounds.first { round in warm.filter { $0.round == round && !$0.failed }.count >= 2 }
      ?? rounds.first
    var answers: [Int: String] = [:]
    for turn in warm where turn.round == round && !turn.failed {
      answers[turn.turn] = turn.requests.flatMap(\.sentences).joined(separator: " ")
    }
    return answers
  }

  private static func seconds(_ value: Double) -> String { String(format: "%.1f s", value) }

  private static func label(_ index: Int) -> String {
    String(UnicodeScalar(UInt8(ascii: "A") + UInt8(index)))
  }
}

/// SplitMix64: a small generator that gives the same numbers for the same seed.
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
