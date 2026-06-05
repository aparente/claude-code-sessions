#!/bin/bash
# claude-restore: Reopen all named Claude sessions from the last checkpoint.
# Restores cmux workspace layout if available.
#
# Usage:
#   claude-restore                       # Interactive — shows list, asks to confirm
#   claude-restore --yes                 # Skip confirmation
#   claude-restore --list                # Just show what's checkpointed
#   claude-restore --dry-run             # Show what would happen without opening anything
#   claude-restore --prev                # Use the .prev backup (last good tick)
#   claude-restore --from-commit <sha>   # Use a historical checkpoint from
#                                        # the ~/.claude git repo. Find the
#                                        # sha with:
#                                        #   cd ~/.claude && git log --oneline session-checkpoint.json
#
# Supports: cmux (default if installed), Terminal.app fallback (macOS)
# Requires: claude-checkpoint to have run at least once.
# Sessions are resumed by UUID (the checkpoint records sessionId per entry),
# so each tab opens directly rather than landing on the resume picker.

CHECKPOINT="$HOME/.claude/session-checkpoint.json"

# Pre-parse special checkpoint-source flags.
#   --prev               read the prior tick's backup (the live tick may have wiped it)
#   --from-commit <sha>  read a historical checkpoint from the ~/.claude git repo
#                        (useful when a tick already overwrote the .prev backup)
#   --from-file <path>   read an arbitrary checkpoint JSON (for tests, manual
#                        recovery from copies, or restoring someone else's state)
args=()
next_is_commit=0
next_is_file=0
COMMIT_SHA=""
FILE_PATH=""
for a in "$@"; do
  if [[ "$next_is_commit" == "1" ]]; then
    COMMIT_SHA="$a"
    next_is_commit=0
    continue
  fi
  if [[ "$next_is_file" == "1" ]]; then
    FILE_PATH="$a"
    next_is_file=0
    continue
  fi
  if [[ "$a" == "--prev" ]]; then
    CHECKPOINT="$CHECKPOINT.prev"
  elif [[ "$a" == "--from-commit" ]]; then
    next_is_commit=1
  elif [[ "$a" == "--from-file" ]]; then
    next_is_file=1
  else
    args+=("$a")
  fi
done
set -- "${args[@]}"

if [ -n "$FILE_PATH" ]; then
  CHECKPOINT="$FILE_PATH"
fi

if [ -n "$COMMIT_SHA" ]; then
  TMP_CHECKPOINT=$(mktemp -t claude-restore-XXXXXX.json)
  trap 'rm -f "$TMP_CHECKPOINT"' EXIT
  if ! (cd "$HOME/.claude" && git show "$COMMIT_SHA:session-checkpoint.json") > "$TMP_CHECKPOINT" 2>/dev/null; then
    echo "Could not read session-checkpoint.json from $COMMIT_SHA" >&2
    echo "Try: cd ~/.claude && git log --oneline session-checkpoint.json" >&2
    exit 1
  fi
  CHECKPOINT="$TMP_CHECKPOINT"
fi

if [ ! -f "$CHECKPOINT" ]; then
  echo "No checkpoint found at $CHECKPOINT"
  echo "Run claude-checkpoint first."
  exit 1
fi

show_sessions() {
  python3 -c "
import json, datetime, os
d = json.load(open('$CHECKPOINT'))
ts = datetime.datetime.fromtimestamp(d['timestamp']).strftime('%Y-%m-%d %H:%M')
named = d.get('named', [])
print(f'Checkpoint from {ts}: {len(named)} named, {d.get(\"unnamed_count\",0)} unnamed')
print()

by_ws = {}
for s in named:
    ws = s.get('workspace', '')
    by_ws.setdefault(ws or '(no workspace)', []).append(s)

for ws, sessions in sorted(by_ws.items()):
    print(f'  [{ws}]')
    for s in sessions:
        started = datetime.datetime.fromtimestamp(s['startedAt']/1000).strftime('%m/%d %H:%M')
        cwd = s['cwd'].replace(os.path.expanduser('~'), '~')
        print(f'    {s[\"name\"]:33s}  {started}  {cwd}')
    print()
"
}

if [[ "$1" == "--list" ]]; then
  show_sessions
  exit 0
fi

show_sessions

if [[ "$1" != "--yes" && "$1" != "--dry-run" ]]; then
  read -r -p "Restore all named sessions? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
fi

# Detect terminal multiplexer
if [[ "$1" == "--dry-run" ]]; then
  MODE="dry-run"
elif command -v cmux &>/dev/null; then
  MODE="cmux"
elif [[ "$OSTYPE" == darwin* ]]; then
  MODE="terminal"
else
  MODE="echo"
fi

python3 -c "
import json, subprocess, shlex, time, sys, os

d = json.load(open('$CHECKPOINT'))
mode = '$MODE'

# Drop sessions whose UUID is already in the LIVE checkpoint — they're
# either still running or about to be reopened twice.
live_path = os.path.expanduser('~/.claude/session-checkpoint.json')
live_uuids = set()
try:
    live = json.load(open(live_path))
    live_uuids = {s.get('sessionId') for s in live.get('named', []) if s.get('sessionId')}
except Exception:
    pass

original_named = d.get('named', [])
skipped = []
filtered = []
for s in original_named:
    if s.get('sessionId') in live_uuids:
        skipped.append(s['name'])
    else:
        filtered.append(s)
d['named'] = filtered
if skipped and mode != 'dry-run':
    print(f'  skipped {len(skipped)} already-running: {\", \".join(skipped)}', file=sys.stderr)

def build_cmd(s):
    # Prefer the full session UUID (resumes directly). Falls back to the
    # name as a picker search term, but that requires manual selection —
    # so warn so the user knows why their tabs are sitting on a picker.
    cwd = s.get('cwd', '')
    sid = s.get('sessionId', '')
    name = s.get('name', '')
    if sid:
        target = sid
    else:
        target = name
        print(f'  WARN: no sessionId for {name!r} — tab will open picker, not resume', file=sys.stderr)
    return f'cd {shlex.quote(cwd)} && claude --resume {shlex.quote(target)}'

def run_cmux(args, label=''):
    # Wrap subprocess.run so cmux failures are visible instead of silent.
    r = subprocess.run(['cmux'] + args, capture_output=True, text=True)
    if r.returncode != 0:
        print(f'  ERR: cmux {args[0]} failed (exit {r.returncode}): {r.stderr.strip()}', file=sys.stderr)
    return r

if mode == 'dry-run':
    # Check existing cmux workspaces
    existing_ws = set()
    try:
        ws_out = subprocess.run(['cmux', 'list-workspaces'], capture_output=True, text=True).stdout.strip().split('\n')
        for line in ws_out:
            parts = line.strip().lstrip('* ').split()
            if len(parts) >= 2:
                existing_ws.add(parts[1])
    except: pass

    by_ws = {}
    for s in d.get('named', []):
        ws = s.get('workspace', '')
        by_ws.setdefault(ws or '(new workspace)', []).append(s)

    for ws_name, sessions in sorted(by_ws.items()):
        exists = ws_name in existing_ws
        label = ' (exists, would add tabs)' if exists else ' (would create)'
        print(f'  [{ws_name}]{label}')
        for s in sessions:
            name = s['name']
            cmd = build_cmd(s)
            print(f'    -> new tab: {name}')
            print(f'       {cmd}')
        print()

elif mode == 'cmux':
    # Get existing workspaces
    ws_out = run_cmux(['list-workspaces']).stdout.strip().split('\n')
    existing_ws = {}
    for line in ws_out:
        parts = line.strip().lstrip('* ').split()
        if len(parts) >= 2:
            existing_ws[parts[1]] = parts[0]

    # Group sessions by workspace
    by_ws = {}
    for s in d.get('named', []):
        ws = s.get('workspace', '')
        by_ws.setdefault(ws, []).append(s)

    failures = []
    for ws_name, sessions in by_ws.items():
        ws_ref = existing_ws.get(ws_name)

        # Create workspace if needed
        if ws_name and not ws_ref:
            run_cmux(['new-workspace'])
            run_cmux(['rename-workspace', ws_name])
            time.sleep(0.3)
            # Re-read to get the ref
            ws_out2 = run_cmux(['list-workspaces']).stdout.strip().split('\n')
            for line in ws_out2:
                parts = line.strip().lstrip('* ').split()
                if len(parts) >= 2 and parts[1] == ws_name:
                    ws_ref = parts[0]
                    existing_ws[ws_name] = ws_ref
                    break

        for s in sessions:
            name = s['name']
            cmd = build_cmd(s)

            # Create new surface (tab) in the target workspace
            if ws_ref:
                result = run_cmux(['new-surface', '--workspace', ws_ref])
                # Parse 'OK surface:62 pane:3 workspace:3' to get surface ref
                surface_ref = None
                for token in result.stdout.strip().split():
                    if token.startswith('surface:'):
                        surface_ref = token
                        break
                if not surface_ref and result.returncode != 0:
                    failures.append(name)
                    continue
                time.sleep(0.2)
                send_args = ['send', '--workspace', ws_ref]
                rename_args = ['rename-tab', '--workspace', ws_ref]
                if surface_ref:
                    send_args += ['--surface', surface_ref]
                    rename_args += ['--surface', surface_ref]
                run_cmux(send_args + [cmd + chr(10)])
                run_cmux(rename_args + [name])
            else:
                run_cmux(['new-workspace', '--command', cmd])

            ws_label = f' [{ws_name}]' if ws_name else ''
            print(f'  opened: {name}{ws_label}')

    if failures:
        print(f'\\nFAILED to open {len(failures)} session(s): {\", \".join(failures)}', file=sys.stderr)

elif mode == 'terminal':
    for s in d.get('named', []):
        name = s['name']
        cmd = build_cmd(s)
        script = f'tell application \"Terminal\" to do script \"{cmd}\"'
        subprocess.run(['osascript', '-e', script])
        print(f'  opened: {name}')

else:
    for s in d.get('named', []):
        name = s['name']
        cwd = s['cwd']
        print(f'  cd {shlex.quote(cwd)} && claude --resume {shlex.quote(name)}')
"
