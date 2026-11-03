# Sourced by ccc: interactive login for every account in the config.
# Uses GUARD_CONFIG, colours and ensure_account_gitconfig from ccc.

# --- Setup mode ---
  echo -e "${GOLD}Claude Code Multi-Account Setup${NC}"
  echo ""
  echo "This will log you into each account in its own config dir."
  echo "You only need to do this once per account."
  echo ""

  # Collect the list first. Looping directly over a pipe would make the
  # `read` prompts below consume the pipe instead of the terminal.
  ACCOUNT_LIST=$(CCC_GUARD="$GUARD_CONFIG" python3 - <<'PY'
import json, os
cfg = json.load(open(os.environ['CCC_GUARD']))
for name, acct in cfg.get('accounts', {}).items():
    email = acct.get('email')
    cd = acct.get('config_dir') or ''
    if not email or not cd:
        continue
    print('%s|%s|%s' % (name, email, os.path.expanduser(cd)))
PY
)

  while IFS='|' read -r name email cd; do
    [ -n "$name" ] || continue
    echo -e "${GOLD}→ $name ($email)${NC}"
    echo "    Config dir: $cd"
    mkdir -p "$cd"

    read -r -p "    Claude: press Enter to login (or 's' to skip): " choice < /dev/tty
    if [ "$choice" != "s" ]; then
      CLAUDE_CONFIG_DIR="$cd" claude auth login --email "$email" || true
    fi

    if command -v gh >/dev/null 2>&1; then
      read -r -p "    GitHub: press Enter to also run 'gh auth login' (or 's' to skip): " ghchoice < /dev/tty
      if [ "$ghchoice" != "s" ]; then
        mkdir -p "$cd/gh"
        ensure_account_gitconfig "$cd"
        GH_CONFIG_DIR="$cd/gh" gh auth login || true
        GH_CONFIG_DIR="$cd/gh" GIT_CONFIG_GLOBAL="$cd/gitconfig" gh auth setup-git || true
      fi
    else
      echo "    (gh CLI not installed — skipping GitHub login. Install: brew install gh)"
    fi
    echo ""
  done <<< "$ACCOUNT_LIST"

  echo -e "${GREEN}Setup complete!${NC} Use 'ccc' to launch Claude Code."
  echo "Each tmux pane can run a different account simultaneously."
  exit 0
