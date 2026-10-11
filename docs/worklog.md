# Worklog

What has actually been done, in order, so the next person — teammate or Claude —
can see where the work stands without reading the diff.

One line per entry, newest at the bottom:

```
- HH:MM [agent] what was asked → what changed — files touched
```

Written by `.claude/helpers/worklog.sh`, never by hand. Agents that change files
append their own line; read-only agents end their report with a `WORKLOG:` line
and the main session appends it.

## 2026-10-11

- 15:05 [main] #1 received: Short memory: work queue, worklog, SessionStart hook
- 15:05 [main] #1 started: Short memory: work queue, worklog, SessionStart hook
- 15:05 [main] #1 done: Short memory: work queue, worklog, SessionStart hook → queue.py and worklog.sh copied from meldestelle, empty queue and worklog, SessionStart hook runs queue.py show, Bash allow for both helpers — .claude/helpers/ .claude/settings.json docs/workQueue.md docs/worklog.md
- 15:05 [main] #2 received: graft wired into Claude Code
- 15:05 [main] #2 started: graft wired into Claude Code
- 15:06 [main] #2 done: graft wired into Claude Code → graft 0.21.1 (already latest, no upgrade) wired for Claude Code only: hooks, statusline, MCP, skill; no global writes — .claude/settings.json .claude/helpers/graft-*.cjs .claude/skills/graft .mcp.json .gitignore .ignore
- 15:06 [main] #3 received: pr-lens and eli5 skills for diagrams
- 15:06 [main] #3 started: pr-lens and eli5 skills for diagrams
- 15:06 [main] #3 done: pr-lens and eli5 skills for diagrams → pr-lens and eli5 skills reviewed (markdown only) and copied for Claude Code, pinned in skills-lock.json — .claude/skills/pr-lens .claude/skills/eli5 skills-lock.json
- 15:32 [main] #4 received: CLAUDE.md project guide and ADRs 0001-0005
- 15:32 [main] #5 received: Agents: core, ui, research, answer, audit
- 15:32 [main] #4 started: CLAUDE.md project guide and ADRs 0001-0005
- 15:35 [main] #4 done: CLAUDE.md project guide and ADRs 0001-0005 → CLAUDE.md with purpose, v1 goal, Later list, glossary, decisions, macOS and Claude API facts, agents, git, queue, layout, commands, open questions; ADRs 0001-0005 — CLAUDE.md docs/adr/
- 15:36 [main] #5 started: Agents: core, ui, research, answer, audit
- 15:38 [main] #5 done: Agents: core, ui, research, answer, audit → agents core and ui (Opus, Swift), research (Opus, read-only), answer (Sonnet, read-only), audit (Fable, read-only, VERDICT); every skill on the shortlists checked to exist — .claude/agents/
- 16:14 [main] #6 received: Rename the assistant to Uriel
- 16:14 [main] #7 received: v1 plan and research findings (ADRs 0006-0008)
- 16:14 [main] #6 started: Rename the assistant to Uriel
- 16:15 [main] #6 done: Rename the assistant to Uriel → assistant, app and wake word renamed from Raphael to Uriel; repo name kept until the owner renames it to code-uriel; dated note in ADR 0003 — CLAUDE.md docs/adr/ .claude/agents/
- 16:15 [research] #7 started: v1 plan and research findings (ADRs 0006-0008)
- 16:18 [research] #7 done: v1 plan and research findings (ADRs 0006-0008) → researched v1 (project format, wake word, SpeechAnalyzer, voice, self-trigger, Claude API, latency, conversation defaults); proposed Swift package + XcodeGen, stable signing with hardened runtime and no sandbox, append-only conversations; planned the wake-word and latency spikes, Phase 0 (7 steps) and Phase 1 (11 steps); corrected platform facts — docs/plan.md docs/adr/0006-0008 CLAUDE.md
- 17:17 [main] #8 received: Record the owner's answers to the v1 questions
- 17:17 [main] #8 started: Record the owner's answers to the v1 questions
- 17:18 [main] #8 done: Record the owner's answers to the v1 questions → accepted ADRs 0005-0008, Personal Team signing, targets, defaults, no written DoD; bundle ID still open — CLAUDE.md, docs/plan.md, docs/adr/0005-0008, .claude/agents/core.md
- 17:38 [main] #9 received: Record the bundle ID com.shinnamon.uriel
- 17:38 [main] #9 started: Record the bundle ID com.shinnamon.uriel
- 17:38 [main] #9 done: Record the bundle ID com.shinnamon.uriel → bundle ID com.shinnamon.uriel; no v1 question blocks Phase 0 — CLAUDE.md, docs/plan.md, docs/adr/0007
- 18:30 [main] #10 received: Record the signing identity on this Mac
- 18:30 [main] #10 started: Record the signing identity on this Mac
- 18:30 [main] #10 done: Record the signing identity on this Mac → Personal Team identity valid after adding the WWDR G3 intermediate — CLAUDE.md
- 18:35 [main] #11 received: Phase 0.1: UrielCore package scaffold
- 18:35 [main] #12 received: Phase 0.2: app shell (XcodeGen, MenuBarExtra, signing)
- 18:35 [main] #13 received: Phase 0.3: Claude client with SSE parser
- 18:35 [main] #14 received: Phase 0.4: Keychain store for the API key
- 18:35 [main] #15 received: Phase 0.5: sentence splitter
- 18:35 [main] #16 received: Phase 0.6: latency spike
- 18:35 [main] #17 received: Phase 0.7: wake-word spike
- 18:35 [core] #11 started: Phase 0.1: UrielCore package scaffold
- 18:40 [core] #11 done: Phase 0.1: UrielCore package scaffold → added the UrielCore Swift package scaffold with a Swift Testing smoke test, build ignores, Commands and Repository layout; audit: ship — UrielCore/Package.swift, UrielCore/Sources/UrielCore/UrielCore.swift, UrielCore/Tests/UrielCoreTests/UrielCoreTests.swift, .gitignore, CLAUDE.md, docs/plan.md
- 18:40 [ui] #12 started: Phase 0.2: app shell (XcodeGen, MenuBarExtra, signing)
- 18:49 [ui] #12 done: Phase 0.2: app shell (XcodeGen, MenuBarExtra, signing) → added the XcodeGen app shell: menu-bar item with Quit, Personal Team signing, hardened runtime, audio-input entitlement; CLAUDE.md commands and layout; audit: ship — project.yml, Uriel/UrielApp.swift, Uriel/Uriel.entitlements, CLAUDE.md
- 18:50 [core] #13 started: Phase 0.3: Claude client with SSE parser
- 19:12 [core] #13 done: Phase 0.3: Claude client with SSE parser → added the Claude Messages API client: request and message types that round-trip assistant content, a line-based SSE parser, streaming over an injected transport, 16 tests; audit: ship — UrielCore/Sources/UrielCore/Claude/, UrielCore/Tests/UrielCoreTests/Claude/
- 19:12 [main] #18 received: Correct the Claude API facts from the official docs
- 19:12 [main] #18 started: Correct the Claude API facts from the official docs
- 19:13 [main] #18 done: Correct the Claude API facts from the official docs → corrected sampling, between_tools, text between tool calls, model-bound thinking and preserved-thinking scope from the official docs — CLAUDE.md
- 19:13 [core] #14 started: Phase 0.4: Keychain store for the API key
- 19:23 [core] #14 done: Phase 0.4: Keychain store for the API key → added KeychainAPIKeyStore (login keychain, service com.shinnamon.uriel, account anthropic-api-key) with a round-trip test on a throwaway service and the owner's security commands; audit: ship, corrupt key now reported as corrupt — UrielCore/Sources/UrielCore/Keychain/KeychainAPIKeyStore.swift, UrielCore/Tests/UrielCoreTests/Keychain/KeychainAPIKeyStoreTests.swift, UrielCore/Sources/UrielCore/Claude/ClaudeClient.swift, CLAUDE.md
- 19:23 [core] #15 started: Phase 0.5: sentence splitter
- 19:37 [core] #15 done: Phase 0.5: sentence splitter → added SentenceSplitter: streamed Claude text to sentences with NLTokenizer and a markdown strip for speech, with tests; audit: ship, glossary wording fixed — UrielCore/Sources/UrielCore/Voice/SentenceSplitter.swift, UrielCore/Tests/UrielCoreTests/Voice/SentenceSplitterTests.swift, docs/plan.md, CLAUDE.md
- 19:38 [core] #16 started: Phase 0.6: latency spike

## 2026-10-12

- 00:20 [main] #19 received: Menu-bar icon: the Halo mark
- 00:20 [main] #19 started: Menu-bar icon: the Halo mark
- 00:22 [main] #19 done: Menu-bar icon: the Halo mark → Replaced the waveform.circle SF Symbol with the owner's Halo mark, a template SVG in a new asset catalog — Uriel/Assets.xcassets, Uriel/UrielApp.swift, CLAUDE.md, docs/plan.md
- 00:36 [main] #20 received: Record the API key types and workspace scoping
- 00:36 [main] #20 started: Record the API key types and workspace scoping
- 00:37 [main] #20 done: Record the API key types and workspace scoping → Recorded that Console keys are identity-backed (sk-ant-usr personal keys), that an unscoped key needs anthropic-workspace-id, and that the owner's key is scoped to one workspace — CLAUDE.md
