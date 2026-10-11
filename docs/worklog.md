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
