#!/bin/bash
# Snapshot all live Claude Code sessions + cmux workspace layout.
# Dead PIDs are pruned. Run via launchd every 5 minutes.

CHECKPOINT="$HOME/.claude/session-checkpoint.json"
SESSIONS_DIR="$HOME/.claude/sessions"

[ -d "$SESSIONS_DIR" ] || exit 0

live=()
for f in "$SESSIONS_DIR"/*.json; do
  [ -f "$f" ] || continue
  pid=$(basename "$f" .json)
  kill -0 "$pid" 2>/dev/null || continue
  entry=$(python3 -c "
import json
d = json.load(open('$f'))
print(json.dumps({
  'pid': d.get('pid'),
  'sessionId': d.get('sessionId',''),
  'name': d.get('name',''),
  'cwd': d.get('cwd',''),
  'startedAt': d.get('startedAt',0)
}))
" 2>/dev/null)
  [ -n "$entry" ] && live+=("$entry")
done

# Capture cmux layout if available
cmux_layout=""
if command -v cmux &>/dev/null; then
  cmux_layout=$(python3 -c "
import subprocess, json

workspaces = subprocess.run(['cmux', 'list-workspaces'], capture_output=True, text=True).stdout.strip().split('\n')
layout = []
for ws_line in workspaces:
    parts = ws_line.strip().lstrip('* ').split()
    ws_ref = parts[0]
    ws_name = parts[1] if len(parts) > 1 else ws_ref
    surfaces = subprocess.run(['cmux', 'list-pane-surfaces', '--workspace', ws_ref], capture_output=True, text=True).stdout.strip().split('\n')
    tabs = []
    for s in surfaces:
        s = s.strip().lstrip('* ')
        sparts = s.split()
        if len(sparts) >= 2:
            sref = sparts[0]
            sname = ' '.join(sparts[1:]).replace('[selected]','').strip()
            is_claude = sname.startswith('✳')
            clean_name = sname.lstrip('✳ ').strip()
            tabs.append({'ref': sref, 'name': clean_name, 'claude': is_claude})
    layout.append({'ref': ws_ref, 'name': ws_name, 'tabs': tabs})
print(json.dumps(layout))
" 2>/dev/null)
fi

tmp="$CHECKPOINT.tmp"
python3 -c "
import json, sys, time

entries = [json.loads(e) for e in sys.argv[1:]]
named = [e for e in entries if e.get('name')]
unnamed_count = len(entries) - len(named)

cmux_raw = '''$cmux_layout'''
cmux = json.loads(cmux_raw) if cmux_raw else None

# Match sessions to cmux workspaces by name
# Try exact match first, then case-insensitive substring
if cmux:
    # Build list of (tab_name, workspace_name) pairs
    all_tabs = []
    for ws in cmux:
        for tab in ws['tabs']:
            all_tabs.append((tab['name'], ws['name']))

    def find_workspace(session_name):
        sn = session_name.lower().replace('_', ' ').replace('-', ' ')
        # Exact match
        for tab_name, ws_name in all_tabs:
            if tab_name == session_name:
                return ws_name
        # Tab name is substring of session name or vice versa (case-insensitive)
        for tab_name, ws_name in all_tabs:
            tn = tab_name.lower().replace('_', ' ').replace('-', ' ')
            if tn in sn or sn in tn:
                return ws_name
        return ''

    for s in named:
        s['workspace'] = find_workspace(s['name'])

out = {
    'timestamp': int(time.time()),
    'named': sorted(named, key=lambda x: x.get('startedAt', 0), reverse=True),
    'unnamed_count': unnamed_count,
    'total': len(entries)
}
if cmux:
    out['cmux_layout'] = cmux

json.dump(out, open('$tmp', 'w'), indent=2)
" "${live[@]}"

# Keep prior checkpoint as backup so one bad cycle (e.g., restart-then-tick)
# doesn't wipe the only record of named sessions.
[ -f "$CHECKPOINT" ] && cp "$CHECKPOINT" "$CHECKPOINT.prev"
mv "$tmp" "$CHECKPOINT"

# Commit to ~/.claude (private repo aparente/claude-config) only when the
# named-session set actually changes, so we get ~1 commit per session
# start/stop instead of 288/day from every tick.
CLAUDE_DIR="$HOME/.claude"
if [ -d "$CLAUDE_DIR/.git" ]; then
  extract_names() {
    python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(' '.join(sorted(f\"{s.get('name','')}@{s.get('cwd','')}\" for s in d.get('named', []))))
except Exception:
    print('')
" "$1" 2>/dev/null
  }

  new_names=$(extract_names "$CHECKPOINT")
  prev_path=$(mktemp)
  (cd "$CLAUDE_DIR" && git show HEAD:session-checkpoint.json 2>/dev/null > "$prev_path")
  old_names=$(extract_names "$prev_path")
  rm -f "$prev_path"

  if [ "$new_names" != "$old_names" ]; then
    count=$(python3 -c "import json; print(len(json.load(open('$CHECKPOINT')).get('named',[])))" 2>/dev/null || echo "?")
    summary=$(python3 -c "
import json
d = json.load(open('$CHECKPOINT'))
names = [s.get('name','') for s in d.get('named',[])][:5]
print(', '.join(names) if names else '(none)')
" 2>/dev/null || echo "")
    (
      cd "$CLAUDE_DIR" || exit 0
      git add session-checkpoint.json session-checkpoint.json.prev 2>/dev/null
      git commit -m "Checkpoint: $count named sessions ($summary)" >/dev/null 2>&1 \
        && git push origin >/dev/null 2>&1 &
    )
  fi
fi
