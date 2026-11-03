# Sourced by ccc: `ccc --doctor` checks everything ccc depends on and
# reports each problem with a fix. Read-only: it never logs in or edits.
# Uses GUARD_CONFIG, CCC_LIB and the colours from ccc.

trap - ERR
PROBLEMS=0
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
bad()  { echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "      → $2"; PROBLEMS=$((PROBLEMS+1)); }
warn() { echo -e "  ${GOLD}⚠${NC} $1"; }

echo -e "${GOLD}ccc doctor${NC}"

# 1. The launcher itself: is the code safe in git?
CCC_REPO="$(dirname "$CCC_LIB")"
echo "Launcher ($CCC_REPO)"
ok "claude $(claude --version 2>/dev/null | head -1)"
if [ -n "$(git -C "$CCC_REPO" status --porcelain 2>/dev/null)" ]; then
  bad "Uncommitted changes in the launcher repo" "commit and push them, or they can be lost"
elif [ -n "$(git -C "$CCC_REPO" log --oneline '@{u}..' 2>/dev/null)" ]; then
  bad "Launcher commits not pushed" "git -C $CCC_REPO push"
else
  ok "Launcher code is committed and pushed"
fi
LINK="$HOME/.local/bin/ccc"
if [ -L "$LINK" ] && [ "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$LINK")" = "$CCC_REPO/ccc" ]; then
  ok "~/.local/bin/ccc points at this repo"
else
  bad "~/.local/bin/ccc is missing or points elsewhere" "bash $CCC_REPO/install.sh"
fi

# 2. The config file.
echo "Config ($GUARD_CONFIG)"
ACCOUNTS=$(CCC_GUARD="$GUARD_CONFIG" python3 - <<'PY' 2>&1
import json, os, sys
cfg = json.load(open(os.environ['CCC_GUARD']))
accounts = cfg.get('accounts', {})
for rule in cfg.get('repo_rules', []):
    if rule.get('account') not in accounts:
        sys.exit("repo_rule points at unknown account %r" % rule.get('account'))
    if 'remote' not in rule and 'match' not in rule:
        sys.exit("repo_rule needs 'remote' or 'match': %r" % rule)
for name, a in accounts.items():
    print('%s|%s|%s' % (name, a.get('email') or '', os.path.expanduser(a.get('config_dir') or '')))
PY
) && ok "Config is valid" || { bad "Config is broken: $ACCOUNTS" "fix $GUARD_CONFIG"; ACCOUNTS=""; }

# 3. Each account: login matches the expected email, gh is logged in.
while IFS='|' read -r name email dir; do
  [ -n "$name" ] || continue
  echo "Account $name ($dir)"
  [ -n "$dir" ] || { warn "no config_dir (API-key account), skipped"; continue; }
  rc=0; got=$(python3 "$CCC_LIB/auth_email.py" "$dir" 2>/dev/null) || rc=$?
  if [ "$rc" -eq 3 ]; then bad "claude auth status did not answer" "CLAUDE_CONFIG_DIR=$dir claude auth status"
  elif [ -z "$got" ]; then bad "Claude: not logged in" "ccc --setup"
  elif [ -n "$email" ] && [ "$got" != "$email" ]; then bad "Claude: logged in as $got, expected $email" "CLAUDE_CONFIG_DIR=$dir claude auth login --email $email"
  else ok "Claude: $got"; fi
  if command -v gh >/dev/null 2>&1; then
    if GH_CONFIG_DIR="$dir/gh" gh auth status >/dev/null 2>&1; then ok "GitHub CLI logged in"
    else warn "GitHub CLI not logged in for this account (ccc --setup)"; fi
  fi
done <<< "$ACCOUNTS"

[ -d "$HOME/.wrangler" ] && warn "Legacy ~/.wrangler exists; Wrangler may ignore the per-account login"

echo ""
if [ "$PROBLEMS" -eq 0 ]; then
  echo -e "${GREEN}All good.${NC}"; exit 0
fi
echo -e "${RED}$PROBLEMS problem(s) found.${NC}"; exit 1
