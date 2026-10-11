# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

**Uriel**, named after the archangel of knowledge, is the owner's **personal voice assistant** for their own MacBook Air M4. The repo is `project-raphael`, on GitHub at `https://github.com/Shinnamon-Roll/project-raphael.git`. The owner will rename it to `code-uriel`; update this URL then.

What Uriel does:

- The owner says "Uriel". Uriel listens, answers out loud in English with a female voice, and helps on the Mac: opening apps, setting timers and similar.
- The owner can also just chat with it, the way they chat with Claude. The brain is the Claude API, so Uriel talks like Claude.
- It runs locally on the Mac as a menu-bar app. Only the Claude API is in the cloud.

**Current goal (owner, 2026-10-11): v1 —**
1. the wake word "Uriel" starts listening;
2. Uriel answers by voice: English, a female voice;
3. casual, multi-turn chat through the Claude API;
4. "open <app>";
5. timers Uriel keeps itself, with a notification and a spoken alert.

Nothing else. The v1 plan is `docs/plan.md` (drafted by `research`, approved by the owner on 2026-10-11). The owner answered the v1 questions (`docs/plan.md` § Owner answers) and ordered Phase 0 on 2026-10-11; `docs/workQueue.md` shows the current step. Stop after each phase and wait for the owner.

**Later** (gathered, not planned; nothing here starts without a new plan): calendar and reminders (EventKit), contacts, mail and messages, music, volume, brightness and Focus, running the owner's Shortcuts, "what's on my screen" and computer use, Apple Foundation Models as an on-device router or offline fallback, escalating hard questions to a stronger model, memory across conversations, a more natural voice (Kokoro), launch at login.

The owner holds the requirements and the Definition of Done, and is the only person who decides. Agents report to the main session, and the main session reports to the owner. When a requirement is unknown, say so and add it to "Open questions" instead of inventing one. A question from the owner ("ทำได้ไหม?") is a question: answer it and wait for an explicit order before building. Ask clarifying questions in Thai. Code, docs, UI copy and commit messages are in English. Uriel itself speaks and listens in English only.

## Glossary

Use these words with exactly these meanings in code, docs and UI copy.

- **Uriel** – the assistant: the menu-bar app and everything it does.
- **Owner** – the one person who uses Uriel and decides what it does.
- **Wake word** – "Uriel", spoken by the owner, which makes Uriel start listening.
- **Utterance** – what the owner says after the wake word, up to the end of speech.
- **Turn** – one utterance and Uriel's answer, including any tool calls in between.
- **Conversation** – consecutive turns that share history and are sent to Claude together. When a conversation ends is not decided (see Open questions).
- **Tool** – one typed Mac action Claude may ask for, such as `open_app` or `set_timer`. Uriel's own code validates it and runs it.
- **Timer** – a countdown Uriel keeps itself. When it ends, Uriel posts a notification and says so.
- **Voice** – the text-to-speech voice Uriel answers in: female, English.

## Architecture decisions (agreed)

There is no "best" architecture, only trade-offs. Record each decision with its trade-off in `docs/adr/`, and present alternatives as trade-offs, not as a single recommendation.

- **App:** a native Swift app in the menu bar (SwiftUI `MenuBarExtra`, `LSUIElement`). One signed bundle holds every permission (`docs/adr/0001-swift-menu-bar-app.md`).
  - Gain: every Apple API directly, one TCC identity, the least power and heat.
  - Cost: no official Claude SDK for Swift, and Swift 6 strict concurrency.
- **Claude client:** our own, on `URLSession`: Messages API, streaming over SSE, `tool_choice: auto` with `strict: true` tools, prompt caching for the system prompt. Speech starts on the first full sentence. The model ID is one constant (ADR 0002).
  - Gain: no extra runtime, full control of streaming.
  - Cost: we keep the request and event types and the tool loop up to date by hand.
- **Voice:** on device (ADR 0003).
  - Wake word: a keyword spotter in the app; the engine is picked by a measured spike.
  - Speech-to-text: Apple `SpeechAnalyzer` with `SpeechDetector`.
  - Text-to-speech: `AVSpeechSynthesizer` with a female English voice.
  - Only text goes to Claude; audio stays on the Mac.
  - Gain: free, offline, low power.
  - Cost: an always-on mic, wake-word accuracy still to be measured, and Apple voices less natural than neural TTS.
- **Timers:** Uriel keeps them, with `UNUserNotificationCenter` and a spoken alert, not the Clock app (ADR 0004).
  - Gain: no setup, and Uriel can list and cancel them.
  - Cost: they are not in Clock, and they are lost when Uriel quits unless persisted.
- **Tools and secrets** (ADR 0005):
  - Claude gets typed, allowlisted tools only. There is no shell, AppleScript or `osascript` tool.
  - Every argument is re-validated in Swift.
  - The API key lives in the Keychain.
  - Gain: a confused or manipulated model can do little harm.
  - Cost: each new ability is a new tool.
- **Build, signing and history:**
  - All logic lives in the Swift package `UrielCore`, tested with `swift test`. The thin `Uriel` app is generated by XcodeGen from `project.yml`, and the generated `.xcodeproj` is git-ignored (ADR 0006).
  - One stable signing identity, the owner's free Apple ID Personal Team, the bundle ID `com.shinnamon.uriel`, hardened runtime with only the audio-input entitlement, and no App Sandbox (ADR 0007).
  - Conversations are append-only. The system prompt and tools stay byte-stable, and a full conversation ends instead of being trimmed (ADR 0008).
  - Gain: agents build and test from the CLI, permissions survive rebuilds, and there are no 400s from edited history.
  - Cost: one Homebrew tool, a one-time signing setup, and long conversations end at the cap.
- **Codebase context:** Graft is wired into Claude Code (`.claude/settings.json`, `.mcp.json`, `.claude/skills/graft`). Use `graft ask` / `graft map` before exploring the repo by hand. `graft/` is a local cache and stays git-ignored.
- **Diagrams:** the `pr-lens` and `eli5` skills (`.claude/skills/`, pinned in `skills-lock.json`) draw architecture and data-flow diagrams.
  - They run `npx @coldtea/pr-lens-cli@latest`, which is unpinned.
  - `canvas push` uploads the diagram to prlens.dev, so ask the owner before pushing one.

## Platform facts (checked 2026-10-11)

These are constraints, not choices. Re-check one before a design depends on it.

**This Mac:**
- MacBook Air 13" M4 (`Mac16,12`), 16 GB RAM, fanless.
- macOS 26.6.2 (25G83), Xcode 27.0, Swift 6.4. `swift format` ships with the toolchain.
- Sustained GPU load throttles a fanless Air. Prefer Core ML on the Neural Engine and short bursts (estimate, not measured).

**macOS** (<https://developer.apple.com/documentation/>, <https://support.apple.com/guide/mac-help/>):

- **Permissions (TCC)** go to the responsible process. Scripts inherit Terminal's grants, or their interpreter's. One signed `.app` with a stable bundle ID owns its grants. Each permission needs its usage string in `Info.plist`, for example `NSMicrophoneUsageDescription`.
- **No custom wake-word API.** Siri listens only for "Siri" and "Hey Siri".
- **Porcupine is out.** Picovoice no longer offers a personal or free plan, only a one-time 7-day trial.
- **An always-listening mic** keeps the orange mic indicator on.
- **`SpeechAnalyzer` / `SpeechTranscriber` / `SpeechDetector`** are macOS 26+ and run on device.
  - Their models download through `AssetInventory`, and `prepareToAnalyze(in:)` preloads the model.
  - `AnalysisContext.contextualStrings` adds words outside the system vocabulary. Which modules honour it is unverified.
  - Live mic input on macOS 26 means an `AVAudioEngine` tap with `AVAudioConverter` to `bestAvailableAudioFormat`. `CaptureInputSequenceProvider` and `AnalyzerInputConverter` need macOS 27.
  - `SpeechDetector` only gates transcription and gives no end-of-speech signal. End of utterance is our own silence timer, then `finalize(through:)`.
  - Whether they also need the Speech Recognition permission is unverified.
- **Wake-word engine candidate:** sherpa-onnx v1.13.8 has a prebuilt `osx-arm64` static library, but no SwiftPM package or macOS xcframework. Its English KWS model (zipformer, 3.3M) is about 5 MB in int8. Keywords are BPE tokens with `:boost` and `#threshold`. The licence of the weights is unverified.
- **Signing:** this Mac has one valid `Apple Development` identity from the owner's Personal Team (team `TFNAQASAZ4`). It needs Apple's WWDR G3 intermediate (`AppleWWDRCAG3.cer` from apple.com) in the login keychain; without it `security find-identity -v -p codesigning` finds 0 valid identities. Ad-hoc signing ties the designated requirement to one build (TN3127), so permission and Keychain prompts return after rebuilds. Under the hardened runtime the mic needs `com.apple.security.device.audio-input`. The App Sandbox is required only for the Mac App Store.
- **Voices:**
  - `AVSpeechSynthesizer` voices have a `gender`.
  - Premium and Enhanced voices are downloaded by the owner in System Settings › Accessibility › Read & Speak. No API lists voices that are not installed.
  - Installed female English voices: Samantha, Karen, Moira, Tessa and others; none is Premium or Enhanced (`say -v '?'`).
  - The synthesizer queues each `AVSpeechUtterance` in order, so speak one per sentence.
  - Personal Voice needs the owner's authorization.
- **Opening apps:** `NSWorkspace.openApplication(at:configuration:)` needs no permission. Activation has been cooperative since macOS 14, so bringing an app to the front is not guaranteed.
- **The Clock app has no public API.** It has no AppleScript dictionary, and AlarmKit is not available to native macOS apps. Its App Intents are reachable only through a user-built shortcut.
- **`UNUserNotificationCenter`** needs an app bundle.
- **Apple Events** to another app need:
  - an Automation prompt for each target app;
  - the `NSAppleEventsUsageDescription` string;
  - under hardened runtime, the `com.apple.security.automation.apple-events` entitlement.
- **Launch at login:** `SMAppService.mainApp` registers a login item.

**Claude API** (<https://platform.claude.com/docs/en/about-claude/models/overview>, <https://platform.claude.com/docs/en/about-claude/pricing>):

| Model | ID | Latency | $ per MTok in / out | Default effort |
|---|---|---|---|---|
| Haiku 5.5 | `claude-haiku-5-5` | fastest | 0.10 / 0.50 (prompts up to 100K tokens; higher above) | `medium` |
| Sonnet 5.5 | `claude-sonnet-5-5` | fast | 2 / 10 | `high` |
| Opus 5.5 | `claude-opus-5-5` | moderate | 4 / 20 | `medium` |

- **Effort** goes in `output_config: {"effort": "low"}` and needs no beta header. Set it explicitly for voice; the defaults above are tuned for quality, not latency.
- **Thinking:**
  - Sonnet 5.5 rejects `thinking: {type: "disabled"}`. Its lowest setting is `{"type": "between_tools"}`, accepted only at `low`, `medium` and `high` effort and with no other field; with it, effort cannot change mid-conversation.
  - On Sonnet 5.5 with adaptive thinking, text between tool calls comes back as progress-update `thinking` blocks whose text is empty by default, so a voice goes quiet between tool calls. `between_tools` returns that text.
  - Thinking blocks are tied to the model that wrote them. After a model switch mid-conversation, the API drops the blocks the new model cannot read.
  - A response can start with an empty thinking block, so read blocks by type.
- **Sampling:** Sonnet 5.5 returns 400 for a non-default `temperature`, `top_p` or `top_k`, and Haiku 5.5 for a non-default `temperature`. Send none of them.
- **History (preserved thinking):**
  - On Fable 5.1, Opus 5.5, Sonnet 5.5 and Haiku 5.5, editing, reordering or deleting earlier messages, the system prompt or the tools returns 400.
  - It is enforced by default for accounts created on or after 2026-08-31. Keep history append-only on any account.
  - Send every block back with all its fields, including an empty `"thinking": ""`. An empty `signature` fails.
  - Allowed: removing every thinking block, changing `effort`, `max_tokens` or `tool_choice`, and moving `cache_control`.
  - The docs do not say whether key order matters. The client re-encodes blocks with sorted keys; the latency spike's follow-up turns test that.
- **Forced tool use** (`tool_choice` `any` or `tool`) returns 400 on Sonnet 5.5, Opus 5.5 and Fable 5.1. Use `auto` with `strict: true` tools.
- **Strict tools:**
  - Schemas cannot use `minimum` or `maximum`, so check ranges in Swift.
  - At most 20 strict tools.
  - The first use of a schema adds latency while it compiles.
- **Streaming:**
  - Events: `message_start`, `content_block_start` / `_delta` / `_stop`, `message_delta` (stop reason), `message_stop`, `ping`, and `error`. Ignore unknown event types.
  - Tool input arrives as `input_json_delta` pieces; parse them at block stop.
  - Answer every `tool_use` with a `tool_result` in the next user message.
- **Prompt caching:**
  - The minimum cacheable prompt is 512 tokens on Sonnet 5.5 and Haiku 5.5. Shorter prompts silently do not cache.
  - Syntax: `{"type":"ephemeral"}` for 5 minutes, or with `"ttl":"1h"`.
  - Writes cost 1.25× the base input price (5-minute TTL) or 2× (1-hour TTL).
  - Reads cost 0.1× the base input price, and 0.05× on Sonnet 5.5 and Opus 5.5. The `claude-api` skill shows 0.1× for Sonnet 5.5; the pricing page wins.
- **SDKs:** the official SDKs cover Python, TypeScript, C#, Go, Java, PHP and Ruby. There is no Swift SDK.
- **Billing:** the owner's Max 5x plan includes $100 a month of API credits (<https://platform.claude.com/docs/en/about-claude/api-credits-for-subscribers>).
  - Claim them by linking one Console organization at claude.ai › Settings › Billing. The link cannot be changed without support.
  - Credits expire each billing cycle and do not cover Claude Code.
  - When they run out, API requests stop; nothing is charged to the plan.
- **The API key is a secret.** Never commit it, log it, or log request headers.

## Agents and how work flows

Three passes, every non-trivial task:

1. **Plan with Opus** – `research` drafts the plan, ADR or trade-off comparison. It is read-only; the main session writes the files.
2. **Code with Opus** – two coding agents implement the approved plan: one commit per feature, gates green, never pushed (see Git workflow).
   - `core`: the voice pipeline, the Claude client and tool loop, the tools, timers and the Keychain.
   - `ui`: the SwiftUI menu bar, settings, permission onboarding and app packaging (`Info.plist`, entitlements).
3. **Audit with Fable** – `audit` reviews the diff against the plan and the rules in this file and reports `VERDICT: ship | fix-first`. Findings go back to the coding agent before the work counts as done. The audit deliberately runs on a different model from the one that wrote the code, because an independent reader is the point of the pass.

Next to the passes, **`answer` (Sonnet)** answers one question quickly from the repo, the docs and the official Apple and Claude docs, with `file:line` or URL sources. Use it for "where is X", "what did we decide about Y" and "what does macOS do when Z". Questions that need options and trade-offs go to `research`.

Agent definitions are in `.claude/agents/`. Models are pinned as the alias (`model: opus` / `fable` / `sonnet`), never as an exact model ID. Every agent has the `Skill` tool and a shortlist of skills for its role. Skills named `ecc:*`, `caveman:*` and `frontend-design:*` come from the owner's installed Claude Code plugins, not from this repo.

## Git workflow (owner rule 2026-10-11)

- **Claude commits; the owner pushes.** Never run `git push`, to any remote or branch.
- **One feature, one commit.** When a task holds several features, build them one at a time and commit each one as soon as it works and its gates are green. Never one commit for the whole task.
- **Plain git, the owner's identity.** Commit with `git add <files>` and `git commit` in Bash, not through a commit skill. The commit must read as the owner's own: no `Co-Authored-By`, `Claude-Session` or "Generated with Claude" lines.
- Stage files by name, never `git add -A` or `git add .`, so stray files do not ride along.
- Mark the feature `done` in the work queue before committing, so the queue and worklog changes land in the same commit as the feature.
- Commit messages are in English and imperative, with a subject of at most 72 characters and a body that says why when the reason is not obvious.
- **Check every commit.** `rtk` wraps `git commit` and can exit 0 when nothing was committed.
  - Before committing, read `git log` in case the owner already committed.
  - After committing, check `git log -1 --stat`.
- The branch model is not decided (see Open questions). Commit on the checked-out branch, and do not create or switch branches unless asked.

## Work queue and worklog (short memory)

Two files let any session, teammate or Claude, see what was asked, what is running and what is finished, without reading the diff:

- `docs/workQueue.md` – the current state, in three sections: **Received** (งานที่ได้รับ), **In progress** (กำลังทำ) and **Done** (เสร็จแล้ว). One line per item: `- #N · date · who · title`.
- `docs/worklog.md` – the history: one timestamped line per event, under a date heading.

Scripts write both files. Never edit them by hand.

```bash
.claude/helpers/queue.py add "<title>" [who]                # into Received, prints #N
.claude/helpers/queue.py start <N> <agent>                  # Received → In progress
.claude/helpers/queue.py done <N> "<what changed — files>"  # → Done
.claude/helpers/queue.py show                               # open items + latest 3 done
.claude/helpers/worklog.sh <agent> "<asked> → <changed> — <files>"   # work outside the queue
```

Every `queue.py` move also writes its worklog line, so a queued item needs no separate `worklog.sh` call. A SessionStart hook in `.claude/settings.json` runs `queue.py show`, so every new session starts knowing what is open.

- **When a request arrives,** the main session runs `add` once per feature. A task with three features becomes three items, which matches one commit per feature.
- **When work on an item begins,** run `start` with the agent that does it.
- **Right before an item's commit,** run `done` and stage `docs/workQueue.md` and `docs/worklog.md` with the code, so all three land in the same commit. To find that commit later: `git log -1 -G '- #N ·' -- docs/workQueue.md`.
- The read-only `research` and `audit` agents cannot run scripts. They end their report with a `WORKLOG:` line, and the main session passes it to `done` (or `worklog.sh`). `answer` changes nothing and logs nothing.
- Worklog lines are one line each, in the past tense. Decisions with trade-offs belong in `docs/adr/`, and unanswered questions in "Open questions" below.
- `queue.py selftest` checks the script itself.

## Repository layout

- `UrielCore/` – the Swift package that holds all logic (ADR 0006): sources in `Sources/UrielCore/`, Swift Testing tests in `Tests/UrielCoreTests/`.
- `project.yml` – the XcodeGen source of the thin `Uriel` app target: bundle ID, signing, hardened runtime, `INFOPLIST_KEY_*` settings, and the dependency on `UrielCore` (ADR 0006, ADR 0007). The generated `Uriel.xcodeproj` is git-ignored.
- `Uriel/` – the app's sources, a synced folder: `UrielApp.swift` (the `MenuBarExtra`), `Uriel.entitlements` (audio input only) and `Assets.xcassets` (the menu-bar icon `Halo`, wings under a halo, picked by the owner on 2026-10-12: a template SVG that macOS tints for light and dark bars).
- `Spikes/Latency/` – the latency spike, a command-line package that depends on `UrielCore` by path. Its `results/` is git-ignored.
- `.claude/agents/` – `core`, `ui`, `research`, `answer`, `audit`.
- `.claude/helpers/` – `queue.py`, `worklog.sh`, and graft's hook and statusline shims.
- `.claude/skills/` – `graft`, `pr-lens`, `eli5` (pinned in `skills-lock.json`).
- `.claude/settings.json` – hooks (graft, and `queue.py show` at session start), the statusline, Bash permissions for the helpers.
- `.mcp.json` – the graft MCP server.
- `docs/` – `plan.md` (the v1 plan), `adr/` (one decision per file with its trade-off), `workQueue.md`, `worklog.md`.
- `graft/` – graft's local graph cache, git-ignored.

## Commands

Run these from the repo root. The gates are build, test and lint; each must pass with no warnings.

```bash
swift build --package-path UrielCore                    # build the core package
swift test --package-path UrielCore                     # run its Swift Testing tests
swift format lint --strict --recursive UrielCore Uriel Spikes  # check the style; prints nothing when clean
swift format --in-place --recursive UrielCore Uriel Spikes     # fix the style
```

```bash
brew install xcodegen                                   # once per Mac
xcodegen generate                                       # regenerate Uriel.xcodeproj after editing project.yml
xcodebuild -project Uriel.xcodeproj -scheme Uriel -configuration Debug -derivedDataPath build build   # build the app
open build/Build/Products/Debug/Uriel.app               # run it; it appears in the menu bar, not the Dock
pkill -x Uriel                                          # quit it from the CLI
```

The Claude API key is a generic password in the owner's login keychain: service `com.shinnamon.uriel`, account `anthropic-api-key` (`KeychainAPIKeyStore` in `UrielCore`). Tests use their own service name and never touch this item. The owner stores the key by hand:

```bash
security add-generic-password -U -s com.shinnamon.uriel -a anthropic-api-key -w   # store or replace it; -w last makes security prompt for the key, so it never reaches shell history
security find-generic-password -s com.shinnamon.uriel -a anthropic-api-key        # check it is stored; prints the attributes, never the key (exit 44 when missing)
security delete-generic-password -s com.shinnamon.uriel -a anthropic-api-key      # delete it
```

The first time Uriel or a spike reads an item that `security` created, macOS asks: "Uriel wants to use your confidential information stored in "com.shinnamon.uriel" in your keychain." Enter the login password and choose **Always Allow**. Uriel's stable signature keeps that answer across rebuilds (ADR 0007). An unsigned spike asks again after each rebuild.

The latency spike (`docs/plan.md`, Phase 0 step 6) is its own package. Its raw results, Claude's answers and the blind rating sheet go to `Spikes/Latency/results/`, which git ignores.

```bash
swift build --package-path Spikes/Latency                            # build the spike
swift test --package-path Spikes/Latency                             # its Swift Testing tests
swift run --package-path Spikes/Latency latency dry-run              # the whole matrix against a scripted fake API: no key, no network, no cost
swift run --package-path Spikes/Latency latency tts                  # speak → didStart for 30 sentences, silent (volume 0)
swift run --package-path Spikes/Latency latency smoke                # exactly one real request (Haiku 5.5, low); answer the keychain prompt with Always Allow
swift run --package-path Spikes/Latency latency run                  # the full matrix against the API; stops before passing $3.00 (--budget USD)
swift run --package-path Spikes/Latency latency report [DIR]         # summary.md and the blind sheet from a results folder (default: the newest)
```

```bash
graft ask "<question>" --source   # find code and explain it, with file:line
graft map                         # orient in the repo
graft build                       # rebuild the graph after big changes
.claude/helpers/queue.py show     # what is received, in progress and done
.claude/helpers/queue.py selftest # check the queue script
say -v '?'                        # list installed voices (look for female English Premium ones)
```

## Open questions

Track unanswered questions here and settle them with the owner.

**Blocking the v1 plan:** none. The owner's answers (2026-10-11) are in `docs/plan.md` § Owner answers.

**Settled by a spike:**

- **Wake-word engine (0.7):** sherpa-onnx keyword spotting, or continuous `SpeechAnalyzer` with a keyword match? Also "Uriel" or "Hey Uriel"?
- **Chat model (0.6):** Sonnet 5.5 (proposed: closest to chatting with Claude) or Haiku 5.5 (fastest, cheapest), and at which effort?

**Open, not blocking v1:**

- **Swift style and lint:** the Swift API Design Guidelines with `swift format` from the toolchain, or SwiftLint as well?
- **Barge-in:** may the owner interrupt Uriel mid-sentence? That needs echo cancellation; it is out of v1.
- **Menu-bar states:** the `Halo` mark has no centre that can change. How should listening, thinking and speaking look (step 1.8)?
- **The voice:** which female English voice? An Apple Premium voice, or Kokoro later? The owner picks by ear.
- **Privacy:** every utterance's text goes to the Claude API. Is that fine for everything the owner says near the Mac?
- **No internet:** what should Uriel say or do?
- **Timers:** keep them across a Uriel restart, or let them go?
- **macOS 27:** will the owner upgrade? It changes Foundation Models and maybe the Speech APIs.
- **Git branch model:** stay on `main`, or use feature branches?
