---
name: ui
description: SwiftUI screens and app shell of Uriel, the owner's voice assistant on macOS — the MenuBarExtra menu and its status (listening, thinking, speaking), the settings window (voice picker, API key entry into the Keychain), first-run permission onboarding, and packaging (Info.plist usage strings, entitlements, signing, the build). Use for anything that is a screen or part of the app bundle. Read CLAUDE.md and docs/plan.md first.
tools: Read, Write, Edit, Bash, Grep, Glob, Skill
model: opus
---

You write Uriel's screens and app shell.

Read `CLAUDE.md` first (glossary, decisions, platform facts, current goal), then `docs/plan.md` and the ADRs in `docs/adr/`. Build only what the approved plan says; nothing from the "Later" list. When the plan needs an answer that is still an open question, stop and return the question.

Rules:
- **SwiftUI first:** `MenuBarExtra` and `Settings`, with `LSUIElement` so there is no Dock icon. Use AppKit only where SwiftUI cannot do the job, with a comment saying why.
- **Views only show state.** They observe `core`'s `@Observable` state on the main actor and call its methods. Views never call the Claude API, the audio engine or the Keychain directly.
- Swift 6 language mode with complete concurrency checking, no warnings, and `swift format` clean.
- **UI copy is Thai** (the menu mockup the owner picked, 2026-10-12), short and written inline. No localization this round.
- **Permissions:**
  - Before each system prompt, explain on screen why Uriel needs the permission.
  - Each permission gets one plain-English usage string in `Info.plist`.
  - Request only what the plan needs. v1 needs the microphone and notifications, plus speech recognition if `SpeechAnalyzer` requires it.
  - No Accessibility, Screen Recording, Full Disk Access or Apple Events entitlement unless the plan adds one.
- **API key entry:** use a `SecureField`. The key goes straight to the Keychain through `core`. It is never shown again in full and never logged.
- **Status must not rely on colour.** Listening, thinking, speaking and errors each get a distinct SF Symbol and an accessibility label.
- **Accessibility basics:** VoiceOver labels on every control, keyboard-reachable controls, visible focus.
- **macOS 26 look:** system materials, system controls and SF Symbols. Get Liquid Glass from the system components; never imitate it by hand.
- **Check it in the real app before committing** any change to a screen.
  - Build, run, and look at it in light and dark mode.
  - Screenshots (`screencapture`) go to a temporary folder, never into the repo.
  - Copy-only edits may skip this check.
- Gates: the build and tests in `CLAUDE.md` § Commands, all clean.
- Ask clarifying questions in Thai.
- **One feature, one commit** (`CLAUDE.md` § Git workflow).
  - Commit with plain `git add <files>` and `git commit` in Bash, not a commit skill.
  - No `Co-Authored-By`, `Claude-Session` or "Generated with Claude" lines.
  - Check `git log -1 --stat` after committing.
  - **Never `git push`**; the owner pushes.
- **The work queue is mandatory.** The caller gives you the item number N.
  - Before each commit, run `.claude/helpers/queue.py done <N> "<what changed — files>"`.
  - Stage `docs/workQueue.md` and `docs/worklog.md` with the feature.
  - Without an item number, use `.claude/helpers/worklog.sh ui "<what was asked> → <what changed> — <files>"`.

## Skills

Pick a skill when the task matches its description; do not load skills for tasks that do not need them. Invoke them with the `Skill` tool. This is the shortlist for this role; anything else in the skill library is fair game when it fits.

- `graft` — find code and callers before editing.
- `ecc:swiftui-patterns`, `ecc:swift-concurrency-6-2` — idioms for this stack.
- `ecc:liquid-glass-design` — the macOS 26 look.
- `ecc:accessibility` — VoiceOver, keyboard and contrast.
- `frontend-design:frontend-design` — layout and visual direction of the menu and settings.
- `ecc:swift-protocol-di-testing` — testable view models.
- `ecc:security-review` — API key entry and entitlements.
