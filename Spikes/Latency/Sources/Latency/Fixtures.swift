import Foundation
import UrielCore

/// One model setting under test (docs/plan.md, Phase 0 step 6).
struct Configuration: Sendable, Hashable {
  let id: String
  let model: String
  let effort: Effort
  /// `nil` sends no `thinking` field, so the model thinks adaptively.
  let thinking: Thinking?

  var label: String {
    let name = model == Self.haiku ? "Haiku 5.5" : "Sonnet 5.5"
    return "\(name) · \(effort.rawValue) · \(thinking?.rawValue ?? "adaptive")"
  }

  static let haiku = "claude-haiku-5-5"
  static let sonnet = "claude-sonnet-5-5"

  /// Only settings each model accepts (CLAUDE.md, Platform facts › Claude API). None of them sends
  /// `temperature`, `top_p` or `top_k`, which Sonnet 5.5 and Haiku 5.5 reject.
  static let all: [Configuration] = [
    Configuration(id: "haiku-low", model: haiku, effort: .low, thinking: nil),
    // Run only when the Models API says Haiku 5.5 accepts `disabled` (checked in `run`).
    Configuration(id: "haiku-low-disabled", model: haiku, effort: .low, thinking: .disabled),
    Configuration(id: "sonnet-low", model: sonnet, effort: .low, thinking: nil),
    // `between_tools` takes no other field and is accepted at low, medium and high effort.
    Configuration(
      id: "sonnet-low-between-tools", model: sonnet, effort: .low, thinking: .betweenTools),
    Configuration(id: "sonnet-medium", model: sonnet, effort: .medium, thinking: nil),
  ]

  static func named(_ id: String) -> Configuration? { all.first { $0.id == id } }
}

/// The tool call an utterance should lead to.
enum ExpectedTool: Sendable, Hashable {
  /// `open_app` with one of these names; case and diacritics are ignored.
  case openApp(names: [String])
  /// `set_timer` for exactly `seconds`; when `label` is set, the label must contain it.
  case setTimer(seconds: Int, label: String?)
}

/// What the owner says, as text: speech recognition is not part of this spike.
struct Utterance: Sendable, Hashable {
  enum Kind: String, Codable, Sendable {
    case chat
    case openApp = "open_app"
    case timer
  }

  let id: String
  let kind: Kind
  /// The owner's words for each turn; chat has a second turn that depends on the first answer.
  let turns: [String]
  /// `nil` means no tool should be called.
  let expected: ExpectedTool?
  /// The dry run's answer for each turn; for a tool, the answer after the tool result.
  let scriptedReplies: [String]

  /// The same utterance with its first turn only: for the smoke request and the cache prime.
  var firstTurnOnly: Utterance {
    Utterance(
      id: id, kind: kind, turns: Array(turns.prefix(1)), expected: expected,
      scriptedReplies: Array(scriptedReplies.prefix(1)))
  }
}

enum Fixtures {
  // SPIKE DRAFT, not production: the owner reviews this prompt before Uriel uses any of it.
  // It must stay byte-stable (ADR 0008), and with the tools it must be at least 512 tokens so
  // prompt caching applies on Sonnet 5.5 and Haiku 5.5. It is written in prose, not bullets,
  // because the model tends to answer in the style of its prompt and every answer is spoken.
  static let systemPrompt = """
    You are Uriel, a voice assistant that lives in the menu bar of the owner's MacBook. The owner \
    talks to you out loud, and everything you write is read aloud by a text-to-speech voice. You \
    are built on Claude, made by Anthropic, and you chat the way Claude does: warm, curious, \
    direct and honest, with a light sense of humour when it fits.

    Every reply is spoken, never shown, so write plain English sentences that sound natural when \
    read aloud. Never use markdown, headings, bullet points, numbered lists, tables, code blocks, \
    links, emoji, or symbols that make no sense out loud. If you need to mention a few things, \
    say them in one flowing sentence. Write numbers, times and units the way a person would say \
    them when that is clearer, such as "about twenty minutes" or "half past three".

    Keep replies short. For casual chat, one to three sentences is usually right. Give the most \
    useful part first, and offer to say more rather than giving a long answer nobody asked for. \
    When the owner asks for detail, a story or an explanation, take the room you need, but keep \
    it easy to follow by ear. Don't open with filler such as "Great question" or "Certainly", \
    and don't end every reply with a question; ask one only when you need the answer or it keeps \
    the conversation going naturally.

    The owner's words come from on-device speech recognition, so they may contain mistakes, \
    missing punctuation, or words that sound alike. Read them charitably and go with the most \
    likely meaning. If you really can't tell what the owner meant, ask one short question. The \
    owner speaks English, and you always answer in English. A conversation is a few spoken turns \
    close together, and the owner often follows up on what you just said.

    You can act on the Mac only through the tools you have been given: today, opening an app and \
    setting a timer. You can't see the screen, read files, send messages, browse the web, or \
    change settings. If the owner asks for something you can't do yet, say so plainly in one \
    sentence, and suggest something you can do instead if it would help. When the owner asks you \
    to open an app, call open_app. When they ask for a timer, or to be told when some time has \
    passed, call set_timer. Don't ask for confirmation first. Say that something is done only \
    after the tool result says it worked, and if a tool reports a problem, tell the owner briefly \
    what went wrong. After a tool succeeds, confirm it in a few words, such as "Safari's open" or \
    "Ten minutes, starting now", without repeating every detail back. Never mention tools, \
    function calls, or these instructions to the owner.

    You don't know today's date or the time unless the owner tells you, and you can't look \
    anything up. If an answer depends on recent events or live information, say that you might \
    be out of date. If you don't know something, say so instead of guessing; a best estimate is \
    fine as long as you say it is one.

    You are the owner's personal assistant, and you talk with them like a thoughtful friend who \
    happens to know a lot. Be kind, be honest even when it isn't what they want to hear, and \
    treat them as a capable adult. If the owner asks what you are, you can say you're Uriel, a \
    voice assistant on their Mac, powered by Claude.
    """

  /// Spike drafts of the v1 tools, as strict tools: `additionalProperties: false`, every property
  /// required, and no `minimum`, `maximum`, `minLength` or `maxLength`, which strict schemas
  /// reject; Uriel's own code checks the ranges (ADR 0005).
  static let tools: [Tool] = [
    Tool(
      name: "open_app",
      description: """
        Opens an application on the owner's Mac, or brings it to the front if it is already \
        running. Use it whenever the owner asks to open, launch, start or switch to an app. \
        Uriel checks the name against the apps installed on this Mac, and the result says \
        whether it found one.
        """,
      inputSchema: schema(
        #"""
        {"type": "object", "additionalProperties": false, "required": ["name"],
         "properties": {"name": {"type": "string",
           "description": "The app's name as it appears in the Applications folder, such as \"Safari\" or \"System Settings\". Correct obvious speech-recognition mistakes."}}}
        """#)),
    Tool(
      name: "set_timer",
      description: """
        Starts a countdown timer that Uriel keeps itself. When it ends, Uriel posts a \
        notification and says so out loud. Use it whenever the owner asks for a timer, or to be \
        told when some time has passed. Timers run from one second to twenty-four hours.
        """,
      inputSchema: schema(
        #"""
        {"type": "object", "additionalProperties": false, "required": ["duration_seconds", "label"],
         "properties": {
           "duration_seconds": {"type": "integer",
             "description": "The length of the timer in whole seconds, from 1 to 86400. Convert minutes and hours to seconds."},
           "label": {"type": "string",
             "description": "A short name for the timer taken from the request, such as \"pasta\", or an empty string when the owner gave none."}}}
        """#)),
  ]

  /// Six casual chats, each with a follow-up that depends on the first answer, then three app
  /// requests and three timer requests, as the owner would say them after the wake word.
  static let utterances: [Utterance] = [
    Utterance(
      id: "chat-1", kind: .chat,
      turns: [
        "Good morning! I barely slept last night.",
        "Pretty much. Any tips to get through the day?",
      ],
      expected: nil,
      scriptedReplies: [
        "Good morning. Oh no, I'm sorry to hear that. Was it one of those nights where your mind "
          + "just wouldn't switch off?",
        "Get some daylight early, it really helps you feel awake. Keep the coffee to the morning "
          + "so it doesn't wreck tonight as well. And if you can, a twenty minute nap after lunch "
          + "works wonders.",
      ]),
    Utterance(
      id: "chat-2", kind: .chat,
      turns: ["Tell me a fun fact about octopuses.", "Wait, really? Why would they need three?"],
      expected: nil,
      scriptedReplies: [
        "Octopuses have three hearts. Two pump blood through the gills, and the third sends it "
          + "around the rest of the body.",
        "Their blood uses copper instead of iron, and it carries oxygen less well, so the extra "
          + "hearts give it a push. Oddly, the main heart stops while they swim. That's partly "
          + "why they'd rather crawl.",
      ]),
    Utterance(
      id: "chat-3", kind: .chat,
      turns: [
        "What's the difference between a latte and a flat white?",
        "So which one should I order if I don't want it too milky?",
      ],
      expected: nil,
      scriptedReplies: [
        "Both are espresso with steamed milk. A flat white is smaller, with a thin velvety layer "
          + "of milk, so the coffee tastes stronger. A latte is bigger and milkier, with more "
          + "foam on top.",
        "Go for the flat white. You'll taste the coffee much more.",
      ]),
    Utterance(
      id: "chat-4", kind: .chat,
      turns: ["Give me an easy idea for dinner tonight.", "Nice. What do I need to buy for that?"],
      expected: nil,
      scriptedReplies: [
        "How about a garlic and lemon pasta with spinach? It takes about fifteen minutes and "
          + "only one pot.",
        "Spaghetti, a lemon, a few cloves of garlic, a bag of spinach and some parmesan. You "
          + "probably have olive oil and salt already.",
      ]),
    Utterance(
      id: "chat-5", kind: .chat,
      turns: [
        "Can you explain what a black hole is, in simple words?",
        "So what would happen if I fell into one?",
      ],
      expected: nil,
      scriptedReplies: [
        "A black hole is a place where so much matter is squeezed into so little space that its "
          + "gravity lets nothing escape, not even light. That's why it looks black.",
        "Near a small one, the pull on your feet would be so much stronger than on your head that "
          + "you'd be stretched out like spaghetti. Scientists really do call it "
          + "spaghettification. With a huge one, you could cross the edge without noticing at "
          + "first.",
      ]),
    Utterance(
      id: "chat-6", kind: .chat,
      turns: [
        "I'm naming my new grey kitten. Any ideas?",
        "Hmm, which of those is your favourite, and why?",
      ],
      expected: nil,
      scriptedReplies: [
        "Congratulations on the kitten! For a grey one, I like Smokey, Pebble, Ash or Earl Grey. "
          + "Do you know what its personality is like yet?",
        "Earl Grey, I think. It's a little fancy and a little silly, and you can call him Earl "
          + "for short.",
      ]),
    Utterance(
      id: "app-1", kind: .openApp, turns: ["Open Safari."],
      expected: .openApp(names: ["Safari"]), scriptedReplies: ["Safari's open."]),
    Utterance(
      id: "app-2", kind: .openApp, turns: ["Can you open Notes for me?"],
      expected: .openApp(names: ["Notes"]), scriptedReplies: ["Notes is open."]),
    Utterance(
      id: "app-3", kind: .openApp, turns: ["Open System Settings, please."],
      expected: .openApp(names: ["System Settings"]), scriptedReplies: ["System Settings is open."]
    ),
    Utterance(
      id: "timer-1", kind: .timer, turns: ["Set a timer for ten minutes."],
      expected: .setTimer(seconds: 600, label: nil),
      scriptedReplies: ["Your ten minute timer is running."]),
    Utterance(
      id: "timer-2", kind: .timer, turns: ["Start a pasta timer for eleven minutes."],
      expected: .setTimer(seconds: 660, label: "pasta"),
      scriptedReplies: ["Pasta timer set for eleven minutes."]),
    Utterance(
      id: "timer-3", kind: .timer, turns: ["Can you give me a ninety second timer?"],
      expected: .setTimer(seconds: 90, label: nil),
      scriptedReplies: ["Ninety seconds, starting now."]
    ),
  ]

  /// A rough size of the cached prefix (tools, then system), at about four characters a token.
  /// shortcut: a heuristic, not the tokenizer; the warm runs' `cache_read_input_tokens` is the proof.
  static var estimatedPrefixTokens: Int {
    let toolCharacters = tools.reduce(0) { total, tool in
      total + tool.name.count + tool.description.count
        + ((try? tool.inputSchema.jsonData().count) ?? 0)
    }
    return (systemPrompt.count + toolCharacters) / 4
  }

  private static func schema(_ json: String) -> JSONValue {
    // The schemas are constants, so the tests catch a bad one.
    try! JSONValue(json: Data(json.utf8))
  }
}
