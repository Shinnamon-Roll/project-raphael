# Uriel v1 plan

Drafted by `research` and approved by the owner on 2026-10-11. The owner answered the questions below and ordered Phase 0 on 2026-10-11. Stop after each phase and wait for the owner.

## Goal (v1, nothing else)

1. The wake word "Uriel" starts listening.
2. Uriel answers by voice, in English, with a female voice.
3. Casual, multi-turn chat through the Claude API.
4. "Open <app>".
5. Timers Uriel keeps itself, with a notification and a spoken alert.

## Rules

- **One step, one commit.** Each step is built by the named agent and audited by `audit` (Fable) before the next one starts.
- **Decisions this plan relies on:** ADRs 0001–0008, all accepted.
- **Tests:** Swift Testing proves logic wherever it can. Steps that need a mic, a speaker or a permission prompt name their manual check.

## Phase 0: groundwork

1. **`core`: package scaffold.**
   - Files:
     - `UrielCore/Package.swift` (Swift 6 mode, macOS 26) with one smoke test.
     - `.gitignore` entries for `build/`, `.build/`, `Uriel.xcodeproj` and `Spikes/**/audio/`.
     - `CLAUDE.md` § Commands and § Repository layout.
   - Gate: `swift test --package-path UrielCore` and `swift format lint`.
2. **`ui`: app shell.**
   - Files:
     - `project.yml` (XcodeGen).
     - `Uriel/UrielApp.swift` (`MenuBarExtra` with an idle symbol, `LSUIElement`).
     - `Uriel/Uriel.entitlements` (audio input only).
     - Hardened runtime on.
   - Gate: `xcodegen generate` and `xcodebuild … build`.
   - Manual: the icon is in the menu bar and there is no Dock icon. `codesign -d -r-` is not a cdhash and stays the same across rebuilds.
   - Before it runs, the owner adds their Apple ID to Xcode once (Personal Team).
   - Bundle ID: `com.shinnamon.uriel`.
3. **`core`: Claude client.**
   - Contents: request and message types, a line-based SSE parser, and streaming over an injected transport.
   - Tests:
     - SSE fixtures: text; tool use with `input_json_delta`; `ping`; `error`; an unknown event.
     - The request JSON: `output_config.effort`, `cache_control`, `strict`.
4. **`core`: Keychain store for the API key.**
   - Test: a round-trip on a test service name, cleaned up afterwards.
   - Manual: the owner stores the key with `security add-generic-password`.
5. **`core`: sentence splitter.**
   - Contents: `NLTokenizer` sentences and a markdown strip.
   - Tests: abbreviations, decimals, times, and the flush at the end of the stream.
6. **`core`: latency spike.**
   - Files: `Spikes/Latency`, results in `docs/spikes/latency.md`.
   - Configurations: Haiku 5.5 `low`; Haiku `low` with thinking disabled; Sonnet 5.5 `low`; Sonnet `low` with `between_tools`; Sonnet `medium`.
   - Runs: 12 utterances (6 chat with follow-ups, 3 open-app, 3 timer), each 10 times warm and once cold.
   - Measures:
     - p50 and p95 time from request to the first sentence and to the synthesizer's `didStart`;
     - the gaps between sentences;
     - cost per turn;
     - whether the tool calls are correct.
   - The owner rates the chat answers blind for "sounds like Claude". Budget: under $3.
   - Target: at most 1.5 s at p50 to the first spoken word.
   - Settles: **the chat model and its effort**.
7. **`core`: wake-word spike.**
   - Files: `Spikes/WakeWord`, a command-line tool with replay and live modes, run from Terminal.
   - Engines:
     - sherpa-onnx keyword spotting with both English models and `URIEL` tokens from `text2token`, sweeping `#0.15–0.35` and `:boost`;
     - continuous `SpeechAnalyzer` with a fuzzy match, with and without `contextualStrings`.
   - Phrases: "Uriel" and "Hey Uriel" are both measured. The owner picks with the data.
   - Recordings stay local and are never committed:
     - 60 calls: 20 at about 0.5 m, 20 at about 3 m, 20 over media;
     - 2 h with no wake word: 1 h of podcasts or TV, and 1 h of the owner talking, including the near-words "Muriel", "you real", "your eel" and "oriel".
   - Measures: misses out of 60, false triggers per hour, detection delay, and the CPU and power of the tool and of the system speech process.
   - Settles: **the wake-word engine**, recorded as ADR 0009.
   - Target: at most 1 false trigger per 8 h, and at least 57 of 60 calls detected.

## Phase 1: v1 features

1. **`core`: audio capture.**
   - Contents: one `AVAudioEngine` tap, conversion to 16 kHz mono, fan-out, and a gate.
   - A ring buffer keeps about 1.5 s of audio, so the words right after "Uriel" reach the transcriber.
   - Test: synthetic buffers.
   - Manual: the mic prompt appears and the orange indicator is on.
2. **`core`: wake-word detector** behind a protocol, using the engine picked in 0.7.
   - Test: fixtures made with `say -o`, never the owner's voice.
   - Manual: 10 calls.
3. **`core`: transcriber.**
   - Contents: asset install, `prepareToAnalyze`, and end of utterance on an injected clock (about 0.8 s with no new text, capped at 20 s).
   - Test: a fake result stream.
   - Manual: does it need the Speech Recognition permission? The answer settles the `Info.plist` key.
4. **`core`: voice.**
   - Contents:
     - rank the female English voices: premium, then enhanced, then default;
     - save the voice's identifier;
     - speak one `AVSpeechUtterance` per sentence;
     - gate the wake word while speaking, plus about 300 ms.
   - Test: the ranking over a fake voice list.
   - Manual: listen to it.
5. **`core`: conversation and turn loop.**
   - An `@MainActor @Observable` state machine: idle, listening, thinking, speaking, follow-up.
   - History is append-only (ADR 0008), with an idle reset and a turn cap.
   - On a failure, retry once, then speak a failure line. On a refusal, speak a short line.
   - With no internet, the line is in character: Uriel cannot reach heaven (owner, 2026-10-12: "something like she did not link with heaven"). The exact words are picked at this step.
   - Tests: a fake transport and a fake voice; the order of sentences; append-only history; the reset after idle; the 429/529 path.
   - Defaults: the proposed column of the conversation-defaults table below.
6. **`core`: tool loop and `open_app`.**
   - Contents: an index of installed apps, matching that ignores case and diacritics, and `NSWorkspace`.
   - Test: the shape of the `tool_result`. An unknown app or tool returns `is_error`.
   - Manual: "Uriel, open Safari".
7. **`core`: timers.**
   - Tools: `set_timer` (1 s to 24 h, checked in Swift), `list_timers` and `cancel_timer`.
   - When a timer ends: a notification and a spoken alert.
   - Tests: a timer fires once; a cancelled timer never fires; injected clock.
   - Timers are saved and restored when Uriel restarts (owner, 2026-10-12).
   - Test: a saved timer is restored with its remaining time.
   - Manual: the alert arrives after the Mac sleeps.
8. **`ui`: menu status.**
   - Contents: a distinct variant of the `Halo` icon and an accessibility label for each state, and a Quit item.
   - Manual: light and dark mode, VoiceOver.
9. **`ui`: settings.**
   - Contents: a `SecureField` for the API key into the Keychain, and a voice picker with preview.
   - Test: the view model never echoes the key.
10. **`ui`: permission onboarding.**
    - Explain first, then request the mic, notifications, and speech recognition if 1.3 shows it is needed.
    - Manual: `tccutil reset`, then grant and deny each one.
11. **Owner: v1 sign-off.**
    - There is no written Definition of Done. The owner uses Uriel day to day and says when v1 is done.

## Owner answers (2026-10-11)

| Question | Answer | Unblocks |
|---|---|---|
| Signing identity | a free Apple ID Personal Team | 0.2 |
| Bundle ID (changing it later resets permissions) | `com.shinnamon.uriel` | 0.2 |
| Install XcodeGen with Homebrew; confirm ADRs 0005–0008 | yes | 0.2 |
| Wake-word target | at most 1 false trigger per 8 h, at least 57 of 60 detected | 0.7 |
| About 2 h of local room and voice recordings, never committed | allowed | 0.7 |
| Latency target | at most 1.5 s at p50 to the first spoken word | sign-off of 0.6 |
| Conversation defaults | the proposed column below | 1.5 |
| Definition of Done for v1 | none; the owner uses Uriel and decides | 1.11 |

Owner answers (2026-10-12):

| Question | Answer | Unblocks |
|---|---|---|
| Every utterance's text goes to the Claude API | fine | — |
| No internet | an in-character spoken line: Uriel cannot reach heaven | 1.5 |
| Timers across a Uriel restart | kept: saved and restored | 1.7 |
| Menu-bar states | Claude designs them; the halo may turn into a different symbol per state. The owner picks. | 1.8 |

Conversation defaults (the owner chose the proposed column):

| Setting | Options | Proposed |
|---|---|---|
| Follow-up window without the wake word | 0 / 5 / 8 s | 5 s |
| Idle reset | 2 / 5 / 10 min | 5 min (keeps the cache warm) |
| Spoken end | none / local phrases ("goodbye", "that's all") / an `end_conversation` tool | local phrases |
| History cap | 20 / 30 / 50 turns, then start fresh | 30 |
| Kept after the end | nothing (memory is on the Later list) | nothing |

## Later (not in this plan)

Barge-in with echo cancellation, cache keep-alive, the server-side refusal fallback, conversation summaries, and everything on the "Later" list in `CLAUDE.md`.

## Sources (accessed 2026-10-11)

- **Claude API:**
  - platform.claude.com/docs/en/build-with-claude/streaming
  - …/agents-and-tools/tool-use/handle-tool-calls
  - …/build-with-claude/effort
  - …/build-with-claude/prompt-caching
  - …/agents-and-tools/tool-use/strict-tool-use
  - …/build-with-claude/preserved-thinking
- **Apple speech and voices:**
  - developer.apple.com/documentation/speech/ (speechanalyzer, speechdetector, analysiscontext, captureinputsequenceprovider, assetinventory)
  - developer.apple.com/videos/play/wwdc2025/277
  - developer.apple.com/documentation/avfaudio/ (avspeechsynthesizer, avspeechsynthesisvoice)
- **Signing and runtime:**
  - developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
  - …/security/hardened-runtime
  - …/security/app-sandbox
  - …/bundleresources/entitlements/com.apple.security.device.audio-input
- **Tools and libraries:**
  - github.com/yonaskolb/XcodeGen
  - github.com/swiftlang/swift-testing
  - k2-fsa.github.io/sherpa/onnx/kws/
  - github.com/k2-fsa/sherpa-onnx (release v1.13.8)

**Not verified:**
- sherpa-onnx's real CPU cost;
- whether `SpeechAnalyzer` needs the Speech Recognition permission;
- whether Siri voices reach third-party apps;
- the licence of the KWS model weights (fine for personal use; re-check before any distribution).
