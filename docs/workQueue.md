# Work queue

Short memory of the project: what was asked, what is being worked on, and what is
finished. One line per item: `- #N · date · who · title`. The date is the day the
item entered its section; `who` is the requester in Received and the agent in
In progress and Done.

Change this file only with `.claude/helpers/queue.py` (see `CLAUDE.md` § Work
queue and worklog). The full history, with what changed in which files, is
`docs/worklog.md`. The commit that finished item N is
`git log -1 -G '- #N ·' -- docs/workQueue.md`.

## Received (งานที่ได้รับ)

- #29 · 2026-10-12 · owner · Wake-word spike: the sherpa-onnx engine
- #33 · 2026-10-12 · owner · Launch at login

## In progress (กำลังทำ)

- #17 · 2026-10-12 · main · Phase 0.7: wake-word spike

## Done (เสร็จแล้ว)

- #32 · 2026-10-12 · main · Record the owner's answers: timer spoken at next launch, English UI, mic on at launch, launch at login and barge-in in v1, Spotify first after v1
- #28 · 2026-10-12 · core · Wake-word spike: recorder, replay and the Apple engine
- #31 · 2026-10-12 · ui · Mic on/off in Uriel's menu
- #16 · 2026-10-12 · core · Phase 0.6: latency spike
- #30 · 2026-10-12 · main · Make Uriel speak politely with ค่ะ and คะ
- #27 · 2026-10-12 · main · A native menu for Uriel: status, About and Quit
- #26 · 2026-10-12 · main · Give Uriel Kanade Tachibana's personality
- #25 · 2026-10-12 · core · Run the latency spike in Thai
- #24 · 2026-10-12 · core · Split Thai text into spoken sentences
- #23 · 2026-10-12 · main · Switch v1 to Thai
- #22 · 2026-10-12 · main · Keep the owner's Halo state designs for step 1.8
- #21 · 2026-10-12 · main · Record the owner's answers on privacy, offline and timers
- #20 · 2026-10-12 · main · Record the API key types and workspace scoping
- #19 · 2026-10-12 · main · Menu-bar icon: the Halo mark
- #15 · 2026-10-11 · core · Phase 0.5: sentence splitter
- #14 · 2026-10-11 · core · Phase 0.4: Keychain store for the API key
- #18 · 2026-10-11 · main · Correct the Claude API facts from the official docs
- #13 · 2026-10-11 · core · Phase 0.3: Claude client with SSE parser
- #12 · 2026-10-11 · ui · Phase 0.2: app shell (XcodeGen, MenuBarExtra, signing)
- #11 · 2026-10-11 · core · Phase 0.1: UrielCore package scaffold
- #10 · 2026-10-11 · main · Record the signing identity on this Mac
- #9 · 2026-10-11 · main · Record the bundle ID com.shinnamon.uriel
- #8 · 2026-10-11 · main · Record the owner's answers to the v1 questions
- #7 · 2026-10-11 · research · v1 plan and research findings (ADRs 0006-0008)
- #6 · 2026-10-11 · main · Rename the assistant to Uriel
- #5 · 2026-10-11 · main · Agents: core, ui, research, answer, audit
- #4 · 2026-10-11 · main · CLAUDE.md project guide and ADRs 0001-0005
- #3 · 2026-10-11 · main · pr-lens and eli5 skills for diagrams
- #2 · 2026-10-11 · main · graft wired into Claude Code
- #1 · 2026-10-11 · main · Short memory: work queue, worklog, SessionStart hook
