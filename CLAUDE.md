# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

**Raphael** (`project-raphael`, on GitHub at `https://github.com/Shinnamon-Roll/project-raphael.git`) is the owner's **personal voice assistant** for their own MacBook Air M4:

- The owner says "Raphael". Raphael listens, answers out loud in English with a female voice, and helps on the Mac: opening apps, setting timers and similar.
- The owner can also just chat with it, the way they chat with Claude. The brain is the Claude API, so Raphael talks like Claude.
- It runs locally on the Mac as a menu-bar app. Only the Claude API is in the cloud.

**Current goal (owner, 2026-10-11): v1 —**
1. the wake word "Raphael" starts listening;
2. Raphael answers by voice: English, a female voice;
3. casual, multi-turn chat through the Claude API;
4. "open <app>";
5. timers Raphael keeps itself, with a notification and a spoken alert.

Nothing else. Code is not started: the next step is a v1 plan (`research` drafts it, the owner approves it, it is saved as `docs/plan.md`). Stop after each phase and wait for the owner.

**Later** (gathered, not planned; nothing here starts without a new plan): calendar and reminders (EventKit), contacts, mail and messages, music, volume, brightness and Focus, running the owner's Shortcuts, "what's on my screen" and computer use, Apple Foundation Models as an on-device router or offline fallback, escalating hard questions to a stronger model, memory across conversations, a more natural voice (Kokoro), launch at login.

The owner holds the requirements and the Definition of Done, and is the only person who decides. Agents report to the main session, and the main session reports to the owner. When a requirement is unknown, say so and add it to "Open questions" instead of inventing one. A question from the owner ("ทำได้ไหม?") is a question: answer it and wait for an explicit order before building. Ask clarifying questions in Thai. Code, docs, UI copy and commit messages are in English. Raphael itself speaks and listens in English only.

## Glossary

Use these words with exactly these meanings in code, docs and UI copy.

- **Raphael** – the assistant: the menu-bar app and everything it does.
- **Owner** – the one person who uses Raphael and decides what it does.
- **Wake word** – "Raphael", spoken by the owner, which makes Raphael start listening.
- **Utterance** – what the owner says after the wake word, up to the end of speech.
- **Turn** – one utterance and Raphael's answer, including any tool calls in between.
- **Conversation** – consecutive turns that share history and are sent to Claude together. When a conversation ends is not decided (see Open questions).
- **Tool** – one typed Mac action Claude may ask for, such as `open_app` or `set_timer`. Raphael's own code validates it and runs it.
- **Timer** – a countdown Raphael keeps itself. When it ends, Raphael posts a notification and says so.
- **Voice** – the text-to-speech voice Raphael answers in: female, English.

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
- **Timers:** Raphael keeps them, with `UNUserNotificationCenter` and a spoken alert, not the Clock app (ADR 0004).
  - Gain: no setup, and Raphael can list and cancel them.
  - Cost: they are not in Clock, and they are lost when Raphael quits unless persisted.
- **Tools and secrets, proposed:** see ADR 0005; the owner has not confirmed it yet.
  - Claude gets typed, allowlisted tools only. There is no shell, AppleScript or `osascript` tool.
  - Every argument is re-validated in Swift.
  - The API key lives in the Keychain.
  - Gain: a confused or manipulated model can do little harm.
  - Cost: each new ability is a new tool.
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
- **`SpeechAnalyzer` / `SpeechTranscriber` / `SpeechDetector`** are macOS 26+ and run on device. Their models download through `AssetInventory`. `prepareToAnalyze(in:)` preloads the model. There is no custom vocabulary. Whether they also need the Speech Recognition permission is unverified.
- **Voices:**
  - `AVSpeechSynthesizer` voices have a `gender`. Premium and Enhanced voices are downloaded separately; this Mac has none yet (`say -v '?'`).
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

- **Effort:** set it explicitly for voice; the defaults above are tuned for quality, not latency.
- **Forced tool use** (`tool_choice` `any` or `tool`) returns 400 on Sonnet 5.5, Opus 5.5 and Fable 5.1. Use `auto` with `strict: true` tools.
- **Prompt caching:**
  - Writes cost 1.25× the base input price (5-minute TTL) or 2× (1-hour TTL).
  - Reads cost 0.1× the base input price, and 0.05× on Sonnet 5.5 and Opus 5.5.
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

There is no app code yet. The app's layout and its project format (see Open questions) arrive with the v1 plan.

- `.claude/agents/` – `core`, `ui`, `research`, `answer`, `audit`.
- `.claude/helpers/` – `queue.py`, `worklog.sh`, and graft's hook and statusline shims.
- `.claude/skills/` – `graft`, `pr-lens`, `eli5` (pinned in `skills-lock.json`).
- `.claude/settings.json` – hooks (graft, and `queue.py show` at session start), the statusline, Bash permissions for the helpers.
- `.mcp.json` – the graft MCP server.
- `docs/` – `adr/` (one decision per file with its trade-off), `workQueue.md`, `worklog.md`; `plan.md` once v1 is planned.
- `graft/` – graft's local graph cache, git-ignored.

## Commands

Build, run and test commands arrive with the app scaffold in the v1 plan.

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

- **Wake-word engine:** sherpa-onnx keyword spotting or continuous `SpeechAnalyzer` with a keyword match? Settle with a spike on this Mac that measures false triggers per hour, misses and CPU.
- **Chat model:** Sonnet 5.5 (proposed: closest to chatting with Claude) or Haiku 5.5 (fastest, cheapest)? Measure the time to the first spoken word on this Mac before deciding.
- **ADR 0005** (typed tools, Keychain): does the owner confirm it?
- **Project format:** an Xcode project, or a Swift package plus a generator such as XcodeGen? It must produce a signed `.app` with `Info.plist` and entitlements, and build and test from the command line (`xcodebuild`) so agents can run the gates.
- **Swift style and lint:** the Swift API Design Guidelines with `swift format` from the toolchain, or SwiftLint as well?
- **Signing:** local signing is assumed. Is a paid Apple Developer account (Developer ID) wanted?
- **Conversations:**
  - When does a conversation end (a silence timeout, "goodbye")?
  - Is anything kept after it ends?
- **Barge-in:** may the owner interrupt Raphael mid-sentence? That needs echo cancellation.
- **The voice:** which female English voice? An Apple Premium voice, or Kokoro later? The owner picks by ear.
- **Privacy:** every utterance's text goes to the Claude API. Is that fine for everything the owner says near the Mac?
- **No internet:** what should Raphael say or do?
- **Timers:** keep them across a Raphael restart, or let them go?
- **macOS 27:** will the owner upgrade? It changes Foundation Models and maybe the Speech APIs.
- **Git branch model:** stay on `main`, or use feature branches?
- **Definition of Done** for v1.
