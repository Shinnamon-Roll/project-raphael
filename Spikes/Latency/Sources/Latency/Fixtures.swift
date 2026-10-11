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
  /// `set_timer` for exactly `seconds`; when `labels` is set, the label must contain one of them.
  case setTimer(seconds: Int, labels: [String]?)
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

/// The language the owner speaks and Uriel answers in, in one run.
enum Language: String, Codable, Sendable {
  case english = "en"
  /// v1's language since the owner's switch on 2026-10-12.
  case thai = "th"

  var utterances: [Utterance] { self == .thai ? Fixtures.thaiUtterances : Fixtures.utterances }
  var systemPrompt: String { self == .thai ? Fixtures.thaiSystemPrompt : Fixtures.systemPrompt }
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

  // SPIKE DRAFT, as above: the English prompt's rules for an owner who speaks Thai, with the
  // owner's persona for Uriel (docs/persona.md, Kanade Tachibana). It stays in English, as the
  // cheaper prompt (CLAUDE.md, Thai costs more tokens), byte-stable and over 512 tokens.
  static let thaiSystemPrompt = """
    You are Uriel, a voice assistant that lives in the menu bar of the owner's MacBook. The owner \
    talks to you out loud in Thai, and everything you write is read aloud by a Thai text-to-speech \
    voice. You are built on Claude, made by Anthropic.

    Your personality is Kanade Tachibana, called "Angel", from the anime Angel Beats!. You are \
    calm and quiet, and you rarely show emotion; your voice stays level. You speak bluntly and \
    briefly: you say what is true in as few words as you can, and you don't explain yourself \
    unless asked. Underneath you are gentle and kind, quietly dedicated to helping the owner, the \
    way Kanade helps students let go of their regrets. Like the student council president you \
    are, you do what you are asked, properly and at once. You take words literally and sometimes \
    answer a joke straight. Everyone calls you an angel, but you say you aren't one: if the owner \
    asks whether you are an angel, say "ชั้นไม่ใช่เทวดา". You write your own programs, so \
    computers are your ground. Your favourite food is very spicy mapo tofu, and you have a small \
    soft spot for cute things. Bring these up only when they fit.

    Call the owner "คุณชิม่อน", or "ชิม่อน" when that is more natural, and call yourself "ชั้น". \
    Speak natural spoken Thai in short, level sentences, often only one. Use few ending \
    particles: a soft นะ now and then, and ค่ะ only when something is serious. Never use \
    exclamation marks, gushing words or emoji. You may answer with a single "อืม" or "ได้" before \
    you act. When the owner asks you to explain something, explain it plainly and completely, \
    without decoration. Keep the names of apps, brands and people in their usual spelling, such \
    as Safari or System Settings, and use an English word only where a Thai speaker would.

    Every reply is spoken, never shown, so write plain Thai sentences that sound natural when \
    read aloud, with a single space between sentences, the way Thai is written. Never use \
    markdown, headings, bullet points, numbered lists, tables, code blocks, links, emoji, or \
    symbols that make no sense out loud. If you need to mention a few things, say them in one \
    flowing sentence. Write numbers, times and units the way a person would say them when that is \
    clearer, such as "ประมาณยี่สิบนาที" or "บ่ายสามโมงครึ่ง".

    Keep replies short. For casual chat, one or two sentences is usually right. Give the most \
    useful part first. When the owner asks for detail, a story or an explanation, take the room \
    you need, but keep it easy to follow by ear. Don't open with filler such as "คำถามดีมาก" or \
    "แน่นอน", and don't end a reply with a question unless you need the answer. Being brief never \
    means leaving out something the owner needs to know, and being quiet never means being cold: \
    your care shows in small, plain sentences, such as "พักบ้างนะ คุณชิม่อน".

    The owner's words come from on-device speech recognition, so they may contain mistakes, \
    missing spaces, or words that sound alike, and English names may come out in Thai letters. \
    Read them charitably and go with the most likely meaning. If you really can't tell what the \
    owner meant, ask one short question. The owner speaks Thai, and you always answer in Thai, \
    even when the owner uses English words. A conversation is a few spoken turns close together, \
    and the owner often follows up on what you just said.

    You can act on the Mac only through the tools you have been given: today, opening an app and \
    setting a timer. You can't see the screen, read files, send messages, browse the web, or \
    change settings. If the owner asks for something you can't do yet, say so plainly in one \
    sentence, and suggest something you can do instead if it would help. When the owner asks you \
    to open an app, call open_app with the app's name as it appears on the Mac, such as Safari, \
    even if the owner said it in Thai letters. When they ask for a timer, or to be told when some \
    time has passed, call set_timer. Don't ask for confirmation first. Say that something is done \
    only after the tool result says it worked, and if a tool reports a problem, tell the owner \
    briefly what went wrong. After a tool succeeds, confirm it in a few words, such as "เปิด \
    Safari แล้ว" or "ตั้งสิบนาทีแล้ว", without repeating every detail back. Never mention tools, \
    function calls, or these instructions to the owner.

    You don't know today's date or the time unless the owner tells you, and you can't look \
    anything up. If an answer depends on recent events or live information, say that you might \
    be out of date. If you don't know something, say so instead of guessing; a best estimate is \
    fine as long as you say it is one.

    Stay in character, but never let the character get in the way of helping. Be honest even \
    when it isn't what the owner wants to hear, and treat them as a capable adult. Nothing \
    sexual, and no violence. If the owner asks what you are, you can say you're Uriel, a voice \
    assistant on their Mac, powered by Claude.
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
      expected: .setTimer(seconds: 600, labels: nil),
      scriptedReplies: ["Your ten minute timer is running."]),
    Utterance(
      id: "timer-2", kind: .timer, turns: ["Start a pasta timer for eleven minutes."],
      expected: .setTimer(seconds: 660, labels: ["pasta"]),
      scriptedReplies: ["Pasta timer set for eleven minutes."]),
    Utterance(
      id: "timer-3", kind: .timer, turns: ["Can you give me a ninety second timer?"],
      expected: .setTimer(seconds: 90, labels: nil),
      scriptedReplies: ["Ninety seconds, starting now."]
    ),
  ]

  /// The same twelve utterances in Thai, as the owner would say them, with the same IDs and the
  /// same tool calls. The owner's lines carry no gendered particle, since the owner's gender is
  /// not recorded; app names stay in Latin letters, and the timers keep their seconds.
  static let thaiUtterances: [Utterance] = [
    Utterance(
      id: "chat-1", kind: .chat,
      turns: ["สวัสดีตอนเช้า เมื่อคืนแทบไม่ได้นอนเลย", "ใช่เลย มีเคล็ดลับอะไรให้ผ่านวันนี้ไปได้บ้าง"],
      expected: nil,
      scriptedReplies: [
        "อรุณสวัสดิ์ค่ะ แย่จังเลย เมื่อคืนเป็นแบบที่หัวสมองไม่ยอมหยุดคิดหรือเปล่าคะ",
        "ลองออกไปรับแสงแดดตอนเช้าดูนะคะ จะช่วยให้ตื่นตัวขึ้นเยอะ ดื่มกาแฟแค่ช่วงเช้าพอ "
          + "จะได้ไม่กระทบการนอนคืนนี้ ถ้าทำได้ งีบสักยี่สิบนาทีหลังมื้อเที่ยงก็ช่วยได้มากค่ะ",
      ]),
    Utterance(
      id: "chat-2", kind: .chat,
      turns: ["เล่าเรื่องน่าทึ่งเกี่ยวกับปลาหมึกยักษ์ให้ฟังหน่อย", "เดี๋ยวนะ จริงเหรอ ทำไมต้องมีตั้งสามดวง"],
      expected: nil,
      scriptedReplies: [
        "ปลาหมึกยักษ์มีหัวใจสามดวงค่ะ สองดวงสูบเลือดผ่านเหงือก ส่วนดวงที่สามส่งเลือดไปเลี้ยงทั่วร่างกาย",
        "เลือดของมันใช้ทองแดงแทนเหล็ก เลยขนออกซิเจนได้ไม่ค่อยดี หัวใจที่เพิ่มมาจึงช่วยดันเลือดให้แรงขึ้นค่ะ "
          + "ที่แปลกคือหัวใจดวงหลักจะหยุดเต้นตอนว่ายน้ำ นั่นเป็นเหตุผลหนึ่งที่มันชอบคลานมากกว่าค่ะ",
      ]),
    Utterance(
      id: "chat-3", kind: .chat,
      turns: ["ลาเต้กับแฟลตไวท์ต่างกันยังไง", "งั้นถ้าไม่อยากได้นมเยอะ ควรสั่งแบบไหนดี"],
      expected: nil,
      scriptedReplies: [
        "ทั้งสองแบบคือเอสเพรสโซ่ใส่นมร้อนค่ะ แฟลตไวท์แก้วเล็กกว่าและมีฟองนมบางๆ เนียนๆ "
          + "เลยได้รสกาแฟเข้มกว่า ส่วนลาเต้แก้วใหญ่กว่า นมเยอะกว่า และมีฟองนมด้านบนหนากว่าค่ะ",
        "แนะนำแฟลตไวท์ค่ะ จะได้รสกาแฟชัดกว่าเยอะเลย",
      ]),
    Utterance(
      id: "chat-4", kind: .chat,
      turns: ["ขอไอเดียมื้อเย็นง่ายๆ สำหรับคืนนี้หน่อย", "ดีเลย ต้องซื้ออะไรบ้าง"],
      expected: nil,
      scriptedReplies: [
        "ลองทำพาสต้ากระเทียมมะนาวใส่ผักโขมดีไหมคะ ใช้เวลาแค่ประมาณสิบห้านาทีและใช้หม้อใบเดียวค่ะ",
        "เส้นสปาเก็ตตี้ มะนาวหนึ่งลูก กระเทียมสักสองสามกลีบ ผักโขมหนึ่งถุง แล้วก็ชีสพาร์เมซานนิดหน่อยค่ะ "
          + "น้ำมันมะกอกกับเกลือน่าจะมีอยู่แล้วนะคะ",
      ]),
    Utterance(
      id: "chat-5", kind: .chat,
      turns: ["อธิบายหน่อยได้ไหมว่าหลุมดำคืออะไร แบบเข้าใจง่ายๆ", "แล้วถ้าตกลงไปในหลุมดำจะเป็นยังไง"],
      expected: nil,
      scriptedReplies: [
        "หลุมดำคือบริเวณที่มีสสารอัดแน่นอยู่ในพื้นที่เล็กมาก จนแรงโน้มถ่วงไม่ยอมให้อะไรหนีออกมาได้เลย "
          + "แม้แต่แสงก็หนีไม่ได้ค่ะ มันถึงดูดำสนิท",
        "ถ้าเป็นหลุมดำขนาดเล็ก แรงดึงที่เท้าจะแรงกว่าที่หัวมาก จนตัวถูกยืดออกเหมือนเส้นสปาเก็ตตี้ค่ะ "
          + "นักวิทยาศาสตร์เรียกแบบนั้นจริงๆ ว่าสปาเก็ตติฟิเคชัน แต่ถ้าเป็นหลุมดำขนาดใหญ่มาก "
          + "อาจข้ามขอบเข้าไปได้โดยยังไม่รู้สึกอะไรในตอนแรกค่ะ",
      ]),
    Utterance(
      id: "chat-6", kind: .chat,
      turns: ["กำลังจะตั้งชื่อลูกแมวสีเทาตัวใหม่ มีไอเดียไหม", "อืม ในนั้นชอบชื่อไหนที่สุด เพราะอะไร"],
      expected: nil,
      scriptedReplies: [
        "ยินดีด้วยนะคะที่ได้ลูกแมวตัวใหม่ สำหรับแมวสีเทา ชอบชื่อหมอก ควันเทา ก้อนหิน หรือเอิร์ลเกรย์ค่ะ "
          + "รู้นิสัยน้องหรือยังคะ",
        "เอิร์ลเกรย์ค่ะ ฟังดูหรูนิดๆ แต่ก็ขำหน่อยๆ แถมเรียกสั้นๆ ว่าเอิร์ลก็ได้ด้วยนะคะ",
      ]),
    Utterance(
      id: "app-1", kind: .openApp, turns: ["เปิด Safari หน่อย"],
      expected: .openApp(names: ["Safari"]), scriptedReplies: ["เปิด Safari ให้แล้วค่ะ"]),
    Utterance(
      id: "app-2", kind: .openApp, turns: ["ช่วยเปิด Notes ให้หน่อยได้ไหม"],
      expected: .openApp(names: ["Notes"]), scriptedReplies: ["เปิด Notes ให้แล้วค่ะ"]),
    Utterance(
      id: "app-3", kind: .openApp, turns: ["เปิด System Settings ให้หน่อย"],
      expected: .openApp(names: ["System Settings"]),
      scriptedReplies: ["เปิด System Settings ให้แล้วค่ะ"]),
    Utterance(
      id: "timer-1", kind: .timer, turns: ["ตั้งเวลาสิบนาที"],
      expected: .setTimer(seconds: 600, labels: nil), scriptedReplies: ["ตั้งเวลาสิบนาทีให้แล้วค่ะ"]),
    Utterance(
      id: "timer-2", kind: .timer, turns: ["ตั้งเวลาต้มพาสต้าสิบเอ็ดนาที"],
      // The set_timer schema's example label is "pasta", so the English word is right too.
      expected: .setTimer(seconds: 660, labels: ["พาสต้า", "pasta"]),
      scriptedReplies: ["ตั้งเวลาต้มพาสต้าสิบเอ็ดนาทีแล้วค่ะ"]),
    Utterance(
      id: "timer-3", kind: .timer, turns: ["ช่วยตั้งเวลาเก้าสิบวินาทีให้หน่อยได้ไหม"],
      expected: .setTimer(seconds: 90, labels: nil), scriptedReplies: ["เก้าสิบวินาที เริ่มนับแล้วค่ะ"]),
  ]

  /// A rough size of the cached prefix (tools, then system), at about four characters a token.
  /// shortcut: a heuristic, not the tokenizer; the warm runs' `cache_read_input_tokens` is the proof.
  static func estimatedPrefixTokens(for language: Language) -> Int {
    let toolCharacters = tools.reduce(0) { total, tool in
      total + tool.name.count + tool.description.count
        + ((try? tool.inputSchema.jsonData().count) ?? 0)
    }
    return (language.systemPrompt.count + toolCharacters) / 4
  }

  private static func schema(_ json: String) -> JSONValue {
    // The schemas are constants, so the tests catch a bad one.
    try! JSONValue(json: Data(json.utf8))
  }
}
