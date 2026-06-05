# Claude Code session namer — adds an auto-naming prompt to bare `claude` launches.
#
# Add to ~/.zshrc:
#
#   source ~/.local/bin/claude-session-namer.sh
#
# Every time you type `claude` (without -n/-r/-c/-p/--help or a management
# subcommand), it asks for a name. Hit enter to skip and let Claude auto-name.
#
# Pass-through cases (no prompt):
#   claude -r / --resume / -c / --continue / -n / -p / --help
#   claude agents | attach | logs | stop | mcp | plugin | plugins | config |
#          doctor | update | install | migrate-installer | setup-token |
#          remote-control
#
# Note: if you also install cmux-claude-tab-rename, the wrapper from THAT kit
# supersedes this one (zsh keeps whichever function was defined last). The
# tab-rename wrapper does naming AND tab rename, so installing both is fine —
# load order doesn't matter for naming behavior.

claude() {
  # Pass through management subcommands (not new sessions, must not be renamed)
  case "$1" in
    agents|attach|logs|stop|mcp|plugin|plugins|config|doctor|update|install|\
    migrate-installer|setup-token|remote-control)
      command claude "$@"
      return
      ;;
  esac

  # Pass through for resume, continue, one-shot, pipe, help, or already named
  if [[ " $* " =~ " -r " ]] || [[ " $* " =~ " --resume" ]] || \
     [[ " $* " =~ " -c " ]] || [[ " $* " =~ " --help" ]] || \
     [[ " $* " =~ " -n " ]] || [[ " $* " =~ " -p " ]]; then
    command claude "$@"
    return
  fi

  printf "Session name (enter to auto-name): "
  read -r name
  if [[ -n "$name" ]]; then
    command claude -n "$name" "$@"
  else
    command claude "$@"
  fi
}
