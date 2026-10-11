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

- #7 · 2026-10-11 · owner · v1 plan and research findings (ADRs 0006-0008)

## In progress (กำลังทำ)

## Done (เสร็จแล้ว)

- #6 · 2026-10-11 · main · Rename the assistant to Uriel
- #5 · 2026-10-11 · main · Agents: core, ui, research, answer, audit
- #4 · 2026-10-11 · main · CLAUDE.md project guide and ADRs 0001-0005
- #3 · 2026-10-11 · main · pr-lens and eli5 skills for diagrams
- #2 · 2026-10-11 · main · graft wired into Claude Code
- #1 · 2026-10-11 · main · Short memory: work queue, worklog, SessionStart hook
