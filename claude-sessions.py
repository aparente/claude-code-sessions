#!/usr/bin/env python3
"""
claude-sessions: list every Claude Code session that has ever existed.

Distinct from claude-restore (which only sees currently-running sessions).
Reads transcript JSONLs in ~/.claude/projects/ and prints a sortable catalog.

Usage:
  claude-sessions                          # all sessions, newest last
  claude-sessions --cwd ~/foo              # filter by cwd substring
  claude-sessions --name pattern           # filter by session name substring (regex)
  claude-sessions --since 2026-04-01       # only sessions touched after this
  claude-sessions --named                  # only sessions with a custom title
  claude-sessions --json                   # machine-readable JSON
  claude-sessions --resume <substr>        # print `claude --resume <id>` command for matches
  claude-sessions --search "phrase"        # deep-search transcript bodies (uses ripgrep)

The output is designed to pipe into grep, fzf, or awk.

The all-time catalog beats `claude --resume`'s picker because it includes
every session ever — not just whatever the picker decides to surface.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

PROJECTS = Path.home() / ".claude" / "projects"


@dataclass
class Session:
    session_id: str
    name: str = ""
    cwd: str = ""
    git_branch: str = ""
    first_ts: str = ""
    last_ts: str = ""
    first_prompt: str = ""
    msg_count: int = 0
    file: Path = field(default_factory=Path)


def parse_session(path: Path) -> Session | None:
    s = Session(session_id=path.stem, file=path)
    try:
        with path.open("r", errors="replace") as f:
            for line in f:
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                t = d.get("type")

                if t == "custom-title" and d.get("customTitle"):
                    s.name = d["customTitle"]
                elif t == "agent-name" and not s.name and d.get("agentName"):
                    s.name = d["agentName"]

                if not s.cwd and d.get("cwd"):
                    s.cwd = d["cwd"]
                if not s.git_branch and d.get("gitBranch"):
                    s.git_branch = d["gitBranch"]

                ts = d.get("timestamp")
                if ts:
                    if not s.first_ts:
                        s.first_ts = ts
                    s.last_ts = ts

                if t == "user" and not s.first_prompt:
                    msg = d.get("message", {})
                    if isinstance(msg, dict):
                        content = msg.get("content")
                        if isinstance(content, str):
                            s.first_prompt = content
                        elif isinstance(content, list):
                            for block in content:
                                if isinstance(block, dict) and block.get("type") == "text":
                                    s.first_prompt = block.get("text", "")
                                    break
                    s.msg_count += 1
                elif t in ("user", "assistant"):
                    s.msg_count += 1

                if d.get("sessionId"):
                    s.session_id = d["sessionId"]
    except (OSError, IOError):
        return None

    if not s.first_ts and not s.last_ts:
        return None
    return s


def fmt_ts(ts: str) -> str:
    if not ts:
        return ""
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return dt.astimezone().strftime("%m-%d %H:%M")
    except Exception:
        return ts[:16]


def cwd_short(cwd: str) -> str:
    home = str(Path.home())
    if cwd.startswith(home):
        return "~" + cwd[len(home):]
    return cwd


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cwd", help="filter by cwd substring")
    ap.add_argument("--name", help="filter by name (regex)")
    ap.add_argument("--since", help="only sessions touched after YYYY-MM-DD")
    ap.add_argument("--named", action="store_true", help="only sessions with custom title")
    ap.add_argument("--json", action="store_true", help="emit JSON")
    ap.add_argument("--resume", metavar="SUBSTR", help="print resume commands for matches")
    ap.add_argument("--search", metavar="PHRASE", help="restrict to sessions whose transcript contains PHRASE (uses ripgrep)")
    ap.add_argument("--limit", type=int, default=0, help="max rows (0 = all)")
    args = ap.parse_args()

    if not PROJECTS.exists():
        print(f"No projects directory at {PROJECTS}", file=sys.stderr)
        sys.exit(1)

    files = [p for p in PROJECTS.glob("*/*.jsonl") if not p.name.startswith("agent-")]

    if args.search:
        import subprocess
        try:
            r = subprocess.run(
                ["rg", "-l", "-F", "--", args.search, str(PROJECTS)],
                capture_output=True, text=True, check=False,
            )
            hits = {Path(line.strip()) for line in r.stdout.splitlines() if line.strip()}
            files = [p for p in files if p in hits]
        except FileNotFoundError:
            print("ripgrep (rg) not found; --search requires it", file=sys.stderr)
            sys.exit(1)

    sessions: list[Session] = []
    for p in files:
        s = parse_session(p)
        if s:
            sessions.append(s)

    if args.cwd:
        sessions = [s for s in sessions if args.cwd in s.cwd]
    if args.name:
        rx = re.compile(args.name, re.I)
        sessions = [s for s in sessions if rx.search(s.name)]
    if args.named:
        sessions = [s for s in sessions if s.name]
    if args.since:
        sessions = [s for s in sessions if s.last_ts and s.last_ts >= args.since]
    if args.resume:
        substr = args.resume.lower()
        sessions = [s for s in sessions if substr in s.name.lower() or substr in s.session_id.lower()]

    sessions.sort(key=lambda s: s.last_ts)

    if args.limit:
        sessions = sessions[-args.limit:]

    if args.json:
        print(json.dumps([s.__dict__ | {"file": str(s.file)} for s in sessions], indent=2, default=str))
        return

    if args.resume:
        for s in sessions:
            label = s.name or s.session_id[:8]
            print(f"# {label}  {cwd_short(s.cwd)}  {fmt_ts(s.last_ts)}")
            print(f"(cd {s.cwd or '.'} && claude --resume {s.session_id})")
        return

    # Pretty default output: name | last | cwd | preview
    print(f"{'NAME':30s}  {'LAST':12s}  {'MSGS':>5s}  {'CWD':40s}  PREVIEW")
    print("-" * 130)
    for s in sessions:
        name = (s.name or f"({s.session_id[:8]})")[:30]
        last = fmt_ts(s.last_ts)
        cwd = cwd_short(s.cwd)[:40]
        preview = s.first_prompt.replace("\n", " ")[:60]
        print(f"{name:30s}  {last:12s}  {s.msg_count:>5d}  {cwd:40s}  {preview}")
    print(f"\n{len(sessions)} session(s)")


if __name__ == "__main__":
    main()
