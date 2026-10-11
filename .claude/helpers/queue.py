#!/usr/bin/env python3
"""Work queue: every task moves Received -> In progress -> Done in docs/workQueue.md.

  queue.py add "<title>" [who]                 new item in Received, prints #N
  queue.py start <N> <agent>                   Received -> In progress
  queue.py done <N> "<what changed — files>"   Received / In progress -> Done
  queue.py show                                open items + last 3 done (SessionStart hook)
  queue.py selftest

Every move also appends one line to docs/worklog.md through worklog.sh, so the
queue is the current state and the worklog is the history.
"""
import datetime
import pathlib
import re
import subprocess
import sys

SECTIONS = ("Received", "In progress", "Done")
ITEM = re.compile(r"^- #(\d+) · (\S+) · (\S+) · (.+)$")


def parse(text):
    """Split the file into the preamble and the item lines of each section."""
    preamble, items, current = [], {s: [] for s in SECTIONS}, None
    for n, line in enumerate(text.splitlines(), 1):
        header = next((s for s in SECTIONS if line.startswith(f"## {s}")), None)
        if header:
            current = header
        elif current is None:
            preamble.append(line)
        elif ITEM.match(line):
            items[current].append(line)
        elif line.strip():
            sys.exit(f"workQueue.md:{n}: not a queue item, fix it by hand: {line}")
    return preamble, items


def render(preamble, items):
    labels = {"Received": "งานที่ได้รับ", "In progress": "กำลังทำ", "Done": "เสร็จแล้ว"}
    parts = ["\n".join(preamble).strip()]
    for s in SECTIONS:
        parts.append("\n\n".join(filter(None, [f"## {s} ({labels[s]})", "\n".join(items[s])])))
    return "\n\n".join(parts) + "\n"


def take(items, n, sections):
    """Remove item #n from the given sections and return (section, who, title)."""
    for s in sections:
        for line in items[s]:
            m = ITEM.match(line)
            if m and int(m[1]) == n:
                items[s].remove(line)
                return s, m[3], m[4]
    sys.exit(f"#{n} is not in {' or '.join(sections)}")


def add(items, title, who, today):
    ids = [int(ITEM.match(l)[1]) for s in SECTIONS for l in items[s]]
    n = max(ids, default=0) + 1
    items["Received"].append(f"- #{n} · {today} · {who} · {title}")
    return n


def start(items, n, agent, today):
    _, _, title = take(items, n, ("Received", "In progress"))
    items["In progress"].append(f"- #{n} · {today} · {agent} · {title}")
    return title


def done(items, n, today):
    section, who, title = take(items, n, ("In progress", "Received"))
    who = who if section == "In progress" else "main"
    items["Done"].insert(0, f"- #{n} · {today} · {who} · {title}")
    return who, title


def show(items):
    lines = ["Work queue (docs/workQueue.md) — change it only with .claude/helpers/queue.py."]
    for label, picked in (("In progress", items["In progress"]),
                          ("Received", items["Received"]),
                          ("Done, latest 3", items["Done"][:3])):
        lines.append(f"{label}:" + ("" if picked else " none"))
        lines += [f"  {l[2:]}" for l in picked]
    return "\n".join(lines)


def selftest():
    pre, items = parse("# Work queue\n\nintro\n\n## Received\n\n## In progress\n\n## Done\n\n- #3 · 2026-01-01 · main · old\n")
    assert add(items, "first", "owner", "D") == 4 and add(items, "second", "owner", "D") == 5
    assert start(items, 4, "backend", "E") == "first"
    assert done(items, 4, "F") == ("backend", "first")
    assert done(items, 5, "F") == ("main", "second")
    assert [ITEM.match(l)[1] for l in items["Done"]] == ["5", "4", "3"]
    assert parse(render(pre, items)) == (pre, items)
    print("queue.py selftest ok")


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "show"
    if cmd == "selftest":
        return selftest()
    root = pathlib.Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
    path = root / "docs" / "workQueue.md"
    preamble, items = parse(path.read_text())
    today = datetime.date.today().isoformat()
    if cmd == "show":
        return print(show(items))
    if cmd == "add" and len(argv) in (3, 4):
        n = add(items, argv[2], argv[3] if len(argv) == 4 else "owner", today)
        who, event = "main", f"#{n} received: {argv[2]}"
        print(f"#{n}")
    elif cmd == "start" and len(argv) == 4:
        who, event = argv[3], f"#{argv[2]} started: {start(items, int(argv[2]), argv[3], today)}"
    elif cmd == "done" and len(argv) == 4:
        who, title = done(items, int(argv[2]), today)
        event = f"#{argv[2]} done: {title} → {argv[3]}"
    else:
        sys.exit(__doc__)
    path.write_text(render(preamble, items))
    subprocess.run([str(root / ".claude" / "helpers" / "worklog.sh"), who, event], check=True)


if __name__ == "__main__":
    main(sys.argv)
