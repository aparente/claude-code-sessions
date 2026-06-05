# claude-code-sessions

Survive crashes, restarts, and "where did that session go" with your live [Claude Code](https://claude.com/claude-code) sessions.

- **`claude-checkpoint`** — every 5 min, snapshot all your named live Claude sessions to disk. Git-backed history for disaster recovery.
- **`claude-restore`** — replay them on reboot, by UUID, in the right working directories (and the right [cmux](https://github.com/manaflow-ai/cmux) workspaces if you have it).
- **`claude-sessions`** — searchable catalog of every Claude session you have ever started, across every project. Goes back as far as your transcript retention setting (default 30 days).
- **`claude-session-namer`** — optional zsh shell wrapper that asks for a session name on bare `claude` launches, so every session is searchable later.

### Why this exists

Built-in `claude --resume` does technically keep your transcripts (they're in `~/.claude/projects/*/UUID.jsonl`), but the picker has three limits that get painful at scale:

1. **It's scoped to your current directory** — you only see sessions launched from the cwd you're in right now. To find a session from another project, you have to `cd` there first.
2. **It shows the N most-recently-touched, not the set you had active.** After a crash, the picker can't distinguish your 8 working sessions from 200 historical ones.
3. **It loses organizational context** — no record of cwd, no cmux workspace assignment, no "these belonged together."

This kit fixes those:

- `claude-sessions` is the cross-cwd catalog the picker isn't. Filter by date, name regex, cwd substring, or transcript-body search.
- `claude-checkpoint` records the live, named subset — so after a crash you can restore the right 8 sessions, not guess at the right 8 out of 200.
- `claude-restore` reopens them in the original cwds (and the right cmux workspaces if you use cmux).

> **You might also like:** [`cmux-claude-tab-rename`](https://github.com/aparente/cmux-claude-tab-rename) — auto-rename cmux tabs to match Claude session names, with on-exit restore. Sibling project; separate problem.

---

## Why this is additive over cmux's native "Resume Agent Sessions on Reopen"

cmux now has a toggle that auto-relaunches agent terminals when cmux reopens after a quit. **Leave it on — it's good UX for that specific case.** The scripts here cover the failure modes cmux's native feature doesn't:

| Failure mode | cmux native | this kit |
|---|---|---|
| You quit cmux and reopen it | ✓ | ✓ |
| Hard reboot (kernel panic, power loss) | ✗ — cmux state is in-memory | ✓ — disk-based checkpoint persists |
| cmux upgrades and migrates state in a way that loses tabs | ✗ | ✓ |
| You want yesterday's set of sessions, not now's | ✗ | ✓ — `--from-commit <sha>` reads from git history |
| New machine setup with all your active sessions | ✗ | ✓ — checkpoint is git-tracked |
| Sessions started outside cmux's agent integration | ✗ | ✓ — tracks any live Claude process |
| Restore from before a corrupted workspace edit | ✗ | ✓ — restore from a prior commit |

They don't conflict. If cmux relaunches a session and `claude-restore` would try to reopen the same one, `claude-restore` dedupes by UUID against currently-live processes and skips.

---

## Requirements

- **macOS** (the launchd job, Terminal.app fallback, and `claude-restore`'s cmux integration are all macOS-specific. The catalog and core scripts work elsewhere.)
- **Claude Code CLI** on `$PATH`
- **python3** on `$PATH`
- Optional: [cmux](https://github.com/manaflow-ai/cmux) — if installed, restore reopens sessions in their original cmux workspaces. Without it, falls back to Terminal.app.
- Optional: `~/.claude` initialized as a git repo with a private remote — `claude-checkpoint` then commits the checkpoint on each named-session-set change, giving you recoverable history.

---

## Install via Claude Code

Open a Claude Code session and paste:

> Please install the Claude Code session checkpoint/restore/catalog kit from this repo: https://github.com/aparente/claude-code-sessions. Read the README and install all four files into `~/.local/bin/`. Make them executable. Set up the launchd job for `claude-checkpoint` (every 300s, with the plist pattern in the README). Use absolute paths derived from my home directory. Be idempotent — if any of the scripts already exist, replace in place. After install, verify the launchd job is loaded and a checkpoint runs.

---

## Install manually

```bash
mkdir -p ~/.local/bin
for f in claude-checkpoint.sh claude-restore.sh claude-sessions.py claude-session-namer.sh; do
  dest="${f%.sh}"
  dest="${dest%.py}"
  curl -fsSL "https://raw.githubusercontent.com/aparente/claude-code-sessions/main/$f" \
    -o "$HOME/.local/bin/$dest"
  chmod +x "$HOME/.local/bin/$dest"
done
```

Make sure `~/.local/bin` is on your `PATH`. Add the namer to your shell config if you want the auto-naming prompt:

```bash
echo 'source ~/.local/bin/claude-session-namer' >> ~/.zshrc
```

### Schedule `claude-checkpoint` via launchd

Create `~/Library/LaunchAgents/com.claude.session-checkpoint.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude.session-checkpoint</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/YOUR_USERNAME/.local/bin/claude-checkpoint</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Users/YOUR_USERNAME/logs/claude-checkpoint.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/YOUR_USERNAME/logs/claude-checkpoint.log</string>
</dict>
</plist>
```

Then:

```bash
mkdir -p ~/logs
launchctl load ~/Library/LaunchAgents/com.claude.session-checkpoint.plist
launchctl start com.claude.session-checkpoint   # run once now
```

Note: `StartInterval` does not wake macOS from sleep. If your laptop is asleep for 12 hours, you'll get one tick when it wakes — not 144. Expected; the git history fills the gaps.

---

## Verify

```bash
which claude-checkpoint claude-restore claude-sessions
launchctl list | grep com.claude.session-checkpoint

# Force a checkpoint and list what was captured
launchctl start com.claude.session-checkpoint
sleep 2
claude-restore --list

# Catalog of all sessions ever
claude-sessions | head -20
```

---

## Usage

### `claude-checkpoint`

Runs from launchd. You normally don't invoke it directly. Reads `~/.claude/sessions/*.json` (one file per live Claude PID), prunes dead PIDs, captures the cmux workspace layout if cmux is installed, and writes `~/.claude/session-checkpoint.json` + a `.prev` backup. Diff-gated git commit: only commits when the named-session set actually changes (so ~1 commit per session lifecycle event, not 288/day).

### `claude-restore`

```bash
claude-restore                       # shows what would happen, asks, then reopens
claude-restore --yes                 # skip confirmation
claude-restore --list                # just print what's checkpointed
claude-restore --dry-run             # show without doing
claude-restore --prev                # use the .prev backup (one cycle of safety)
claude-restore --from-commit <sha>   # read a historical checkpoint from ~/.claude git history
claude-restore --from-file <path>    # read an arbitrary JSON checkpoint
```

Sessions are resumed by UUID, so each one lands directly in its conversation — no picker. Already-running sessions (matched by UUID against the live checkpoint) are skipped to avoid duplicates.

### `claude-sessions`

```bash
claude-sessions                          # all sessions, newest last
claude-sessions --named                  # only sessions you named
claude-sessions --cwd ~/projects/foo     # filter by cwd substring
claude-sessions --name pattern           # filter by name (regex)
claude-sessions --since 2026-04-01       # only sessions touched after this date
claude-sessions --search "phrase"        # find sessions whose transcripts contain a phrase (uses ripgrep)
claude-sessions --resume substr          # print `claude --resume <id>` commands for matches
claude-sessions --json                   # machine-readable output
```

### `claude-session-namer`

Source it from your `~/.zshrc`. After that, bare `claude` launches prompt for a name:

```
$ claude
Session name (enter to auto-name): protein-analysis
```

Pass-through cases (no prompt): `claude --resume`, `-c`, `-n`, `-p`, `--help`, and management subcommands (`agents`, `attach`, `logs`, `stop`, `mcp`, `plugin`, `config`, etc.).

---

## Pro tip — initialize `~/.claude` as a private git repo

For the history-based recovery to work, `~/.claude` needs to be a git repo. Set up a private remote (GitHub private repo recommended) and the checkpoint script will push every state change automatically.

```bash
cd ~/.claude
git init
gh repo create claude-config --private --source=. --remote=origin
# Add a .gitignore that excludes credentials, sessions/, projects/, statsig/, etc.
# (Or copy from this repo's docs.)
git add session-checkpoint.json
git commit -m "Initial checkpoint"
git push -u origin main
```

After that, `claude-restore --from-commit <sha>` can recover any prior state — useful when both the live checkpoint and `.prev` get overwritten with stale data after a tick fires before you can restore.

---

## Files

| File | Goes to | Purpose |
|---|---|---|
| [`claude-checkpoint.sh`](./claude-checkpoint.sh) | `~/.local/bin/claude-checkpoint` | Every-5-min snapshot of live sessions + workspace layout |
| [`claude-restore.sh`](./claude-restore.sh) | `~/.local/bin/claude-restore` | Reopens checkpointed sessions, by UUID, in their original workspaces |
| [`claude-sessions.py`](./claude-sessions.py) | `~/.local/bin/claude-sessions` | All-time catalog of every Claude session ever |
| [`claude-session-namer.sh`](./claude-session-namer.sh) | source from `~/.zshrc` | Optional: prompts for a name on bare `claude` launches |

## License

[CC0 1.0 Universal](./LICENSE) — public domain.
