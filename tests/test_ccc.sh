#!/bin/bash
# Tests for the ccc (Claude Code launcher) script
#
# Run: bash tests/test_ccc.sh
#
# Tests use a mock environment: fake git, fake claude, temp guard config.
# No real claude sessions are launched.

set -euo pipefail

# Resolve the ccc script relative to this test file so the suite is portable.
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
CCC="$TEST_DIR/../ccc"

PASS=0
FAIL=0
TOTAL=0
TMPDIR_BASE=$(mktemp -d)

# --- Test helpers ---
pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  ✗ $1: $2"; }

cleanup() { rm -rf "$TMPDIR_BASE"; }
trap cleanup EXIT

# --- Mock environment setup ---
MOCK_BIN="$TMPDIR_BASE/mockbin"
mkdir -p "$MOCK_BIN"

# Mock claude: logs args, returns fake auth status when asked
cat > "$MOCK_BIN/claude" << 'MOCK'
#!/bin/bash
# Log invocation
echo "$@" >> "${CCC_TEST_ARGLOG:-/dev/null}"
# Simulate a hung CLI for the auth-timeout test
if [[ "$*" == *"auth status"* ]] && [ -n "${CCC_TEST_AUTH_SLEEP:-}" ]; then sleep "$CCC_TEST_AUTH_SLEEP"; fi
if [ "${1:-}" = "--version" ]; then echo "9.9.9 (Claude Code)"; exit 0; fi
if [ -n "${CCC_TEST_ENVLOG:-}" ]; then
  {
    echo "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-}"
    echo "GH_CONFIG_DIR=${GH_CONFIG_DIR:-}"
    echo "GIT_CONFIG_GLOBAL=${GIT_CONFIG_GLOBAL:-}"
    echo "WRANGLER_HOME=${WRANGLER_HOME:-}"
    echo "XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-}"
    echo "CLAUDE_CODE_AUTO_COMPACT_WINDOW=${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}"
  } >> "$CCC_TEST_ENVLOG"
fi
# Handle auth status --json
if [[ "$*" == *"auth status"* ]] && [[ "$*" == *"--json"* ]]; then
  if [ "${CCC_TEST_LOGGED_OUT:-}" = "1" ]; then
    echo '{"loggedIn":false}'
  else
    echo "{\"email\":\"${CCC_TEST_AUTH_EMAIL-test@personal.com}\"}"
  fi
  exit 0
fi
exit 0
MOCK
chmod +x "$MOCK_BIN/claude"

# Mock git: repo root is the cwd; origin remote comes from a .mock-remote file
# in the repo dir, so a "worktree" can carry a remote its path doesn't hint at.
cat > "$MOCK_BIN/git" << 'MOCK'
#!/bin/bash
if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--show-toplevel" ]; then
  if [ "${CCC_TEST_NO_GIT:-}" = "1" ]; then
    exit 128
  fi
  pwd
  exit 0
fi
if [ "${1:-}" = "remote" ] && [ "${2:-}" = "get-url" ]; then
  if [ -f .mock-remote ]; then cat .mock-remote; exit 0; fi
  exit 1
fi
/usr/bin/git "$@"
MOCK
chmod +x "$MOCK_BIN/git"

# Guard config with test accounts (mirrors the example schema)
mkdir -p "$TMPDIR_BASE/.claude"
cat > "$TMPDIR_BASE/.claude/account-guard.json" << 'JSON'
{
  "default_account": "personal",
  "accounts": {
    "personal": {
      "email": "test@personal.com",
      "config_dir": "~/.claude-personal",
      "description": "Personal account"
    },
    "work": {
      "email": "test@work.example",
      "config_dir": "~/.claude-work",
      "description": "Work account"
    }
  },
  "repo_rules": [
    { "remote": "github.com/Work-Org/", "account": "work" },
    { "match": "work-repo", "account": "work" }
  ]
}
JSON

# Create fake repo dirs (ccc matches against pwd + origin remote)
mkdir -p "$TMPDIR_BASE/repos/my-project"
mkdir -p "$TMPDIR_BASE/repos/work-repo"
mkdir -p "$TMPDIR_BASE/repos/random-unknown"
mkdir -p "$TMPDIR_BASE/repos/wt-alias"
mkdir -p "$TMPDIR_BASE/repos/wt-shouty"
mkdir -p "$TMPDIR_BASE/.claude-personal"
mkdir -p "$TMPDIR_BASE/.claude-work"

# A worktree whose directory name gives no hint — only the remote does.
echo "https://github.com/Work-Org/thing.git" > "$TMPDIR_BASE/repos/wt-alias/.mock-remote"
# Same, with different casing, to prove remote matching is case-insensitive.
echo "git@github.com:WORK-ORG/other.git" > "$TMPDIR_BASE/repos/wt-shouty/.mock-remote"
# A personal repo that does have a remote, just not a matching one.
echo "https://github.com/me/my-project.git" > "$TMPDIR_BASE/repos/my-project/.mock-remote"

# Helper: run ccc in a mock repo directory
# Usage: run_ccc <repo_dir> [args...]
run_ccc() {
  local repo_dir="$1"; shift
  local arglog="$TMPDIR_BASE/arglog-$$-$RANDOM"
  (
    cd "$TMPDIR_BASE/repos/$repo_dir"
    CCC_TEST_ARGLOG="$arglog" \
    CCC_TEST_AUTH_EMAIL="${CCC_TEST_AUTH_EMAIL:-test@personal.com}" \
    PATH="$MOCK_BIN:$PATH" \
    HOME="$TMPDIR_BASE" \
    bash "$CCC" "$@" 2>&1
  )
}

# ============================================================
echo "=== ccc test suite ==="
echo ""

# ============================================================
# Section 1: Static analysis
# ============================================================
echo "--- Static analysis ---"

if bash -n "$CCC" 2>/dev/null; then
  pass "Valid bash syntax"
else
  fail "Valid bash syntax" "bash -n failed"
fi

if grep -q '^set -euo pipefail' "$CCC"; then
  pass "set -euo pipefail enabled"
else
  fail "set -euo pipefail enabled" "missing"
fi

if head -1 "$CCC" | grep -q '^#!/bin/bash'; then
  pass "Has bash shebang"
else
  fail "Has bash shebang" "$(head -1 "$CCC")"
fi

# ============================================================
# Section 2: Variable ordering (nounset safety)
# ============================================================
echo ""
echo "--- Variable ordering (nounset safety) ---"
for VAR in RED GREEN GOLD DIM NC; do
  DEF_LINE=$(grep -n "^${VAR}=" "$CCC" | head -1 | cut -d: -f1)
  USE_LINE=$(grep -n "\${${VAR}}" "$CCC" | head -1 | cut -d: -f1)
  if [ -n "$DEF_LINE" ] && [ -n "$USE_LINE" ] && [ "$DEF_LINE" -lt "$USE_LINE" ]; then
    pass "$VAR defined (line $DEF_LINE) before first use (line $USE_LINE)"
  elif [ -z "$USE_LINE" ]; then
    pass "$VAR defined (never used via \${} — OK)"
  else
    fail "$VAR defined before use" "def=$DEF_LINE use=$USE_LINE"
  fi
done

# ============================================================
# Section 3: exec claude safety (DSP + arg separator)
# ============================================================
echo ""
echo "--- exec claude safety ---"
EXEC_COUNT=$(grep -c 'exec claude' "$CCC")
DSP_COUNT=$(grep -c 'exec claude --dangerously-skip-permissions' "$CCC")
if [ "$EXEC_COUNT" -eq "$DSP_COUNT" ] && [ "$EXEC_COUNT" -gt 0 ]; then
  pass "All $EXEC_COUNT exec claude calls include --dangerously-skip-permissions"
else
  fail "All exec claude calls include DSP" "total=$EXEC_COUNT, with DSP=$DSP_COUNT"
fi

# 3.2 All exec lines use the conditional SEPARATOR array before "$@"
SEPARATOR_COUNT=$(grep -c 'exec claude.*\${SEPARATOR\[@\]+"\${SEPARATOR\[@\]}"} "\$@"' "$CCC")
if [ "$EXEC_COUNT" -eq "$SEPARATOR_COUNT" ]; then
  pass "All $EXEC_COUNT exec claude calls use conditional SEPARATOR before \$@"
else
  fail "All exec claude calls use conditional SEPARATOR" "total=$EXEC_COUNT, with SEPARATOR=$SEPARATOR_COUNT"
fi

# 3.3 SEPARATOR array is defined and conditionally populated
if grep -q 'SEPARATOR=()' "$CCC" && grep -q 'SEPARATOR=(--)' "$CCC"; then
  pass "SEPARATOR array conditionally set based on first user arg"
else
  fail "SEPARATOR array conditionally set" "missing definition or conditional"
fi

# ============================================================
# Section 4: The launcher must not pin session settings
# ============================================================
echo ""
echo "--- No session-setting overrides ---"

# 4.1 No --model flag in executable code. `--model opus` would override the
#     account's settings.json ("model": "opus[1m]") and silently drop the 1M
#     context. Comments may mention it — that's the explanation of why it's gone.
if grep -v '^\s*#' "$CCC" | grep -q -- '--model'; then
  fail "Script never passes --model" "found a --model reference outside comments"
else
  pass "Script never passes --model (settings.json owns the model)"
fi

# 4.2 No legacy mode / context / compaction env artifacts
if grep -q "ROUTINE MODE\|CLAUDE_CODE_DISABLE_1M_CONTEXT\|CLAUDE_CODE_EFFORT_LEVEL\|CLAUDE_CODE_AUTO_COMPACT_WINDOW" "$CCC"; then
  fail "Legacy session-config artifacts removed" "found legacy strings"
else
  pass "Legacy session-config artifacts removed"
fi

# 4.3 Confirm at runtime that claude is invoked without --model
ARGLOG_MODEL="$TMPDIR_BASE/arglog-model"
ENVLOG_MODEL="$TMPDIR_BASE/envlog-model"
(
  cd "$TMPDIR_BASE/repos/my-project"
  CCC_TEST_ARGLOG="$ARGLOG_MODEL" \
  CCC_TEST_ENVLOG="$ENVLOG_MODEL" \
  CCC_TEST_AUTH_EMAIL="test@personal.com" \
  PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" \
  bash "$CCC" 2>&1 >/dev/null
) || true
LAUNCH_ARGS=$(grep -v 'auth status' "$ARGLOG_MODEL" 2>/dev/null || echo "")
if ! echo "$LAUNCH_ARGS" | grep -q -- '--model'; then
  pass "claude launched without --model"
else
  fail "claude launched without --model" "args: $LAUNCH_ARGS"
fi
if grep -q "^CLAUDE_CODE_AUTO_COMPACT_WINDOW=$" "$ENVLOG_MODEL" 2>/dev/null; then
  pass "CLAUDE_CODE_AUTO_COMPACT_WINDOW not exported"
else
  fail "CLAUDE_CODE_AUTO_COMPACT_WINDOW not exported" "env: $(cat "$ENVLOG_MODEL" 2>/dev/null)"
fi

# ============================================================
# Section 5: --status output completeness
# ============================================================
echo ""
echo "--- --status output ---"
OUTPUT=$(run_ccc my-project --status)
for FIELD in "Repo:" "Remote:" "Account:" "Config:" "Desc:" "Login:"; do
  if echo "$OUTPUT" | grep -q "$FIELD"; then
    pass "--status includes $FIELD"
  else
    fail "--status includes $FIELD" "not found"
  fi
done

# ============================================================
# Section 6: Account resolution
# ============================================================
echo ""
echo "--- Account resolution ---"

# 6.1 Path-rule match
OUTPUT=$(CCC_TEST_AUTH_EMAIL="test@work.example" run_ccc work-repo --status)
if echo "$OUTPUT" | grep -q "Account:.*work.*via rule"; then
  pass "work-repo → work account via path rule"
else
  fail "work-repo → work account via path rule" "$OUTPUT"
fi

# 6.2 Remote-rule match wins even when the directory name says nothing
OUTPUT=$(CCC_TEST_AUTH_EMAIL="test@work.example" run_ccc wt-alias --status)
if echo "$OUTPUT" | grep -q "Account:.*work.*via rule"; then
  pass "Worktree with Work-Org remote → work account via remote rule"
else
  fail "Worktree with Work-Org remote → work account" "$OUTPUT"
fi

# 6.3 Remote matching is case-insensitive
OUTPUT=$(CCC_TEST_AUTH_EMAIL="test@work.example" run_ccc wt-shouty --status)
if echo "$OUTPUT" | grep -q "Account:.*work.*via rule"; then
  pass "Remote rule matches case-insensitively (WORK-ORG)"
else
  fail "Remote rule matches case-insensitively" "$OUTPUT"
fi

# 6.4 Non-matching remote does not accidentally route to work
OUTPUT=$(run_ccc my-project --status)
if echo "$OUTPUT" | grep -q "Account:.*personal.*via default"; then
  pass "Repo with an unrelated remote → default account"
else
  fail "Repo with an unrelated remote → default account" "$OUTPUT"
fi

# 6.5 Unmatched repo falls through to default_account, quietly but visibly
OUTPUT=$(run_ccc random-unknown 2>&1 || true)
if echo "$OUTPUT" | grep -q "random-unknown → personal" && echo "$OUTPUT" | grep -q "\[default\]"; then
  pass "Unmatched repo uses default_account and labels it [default]"
else
  fail "Unmatched repo uses default_account" "$OUTPUT"
fi

# 6.6 …and does NOT print the old scary "not in account-guard config" warning
if echo "$OUTPUT" | grep -q "not in account-guard"; then
  fail "No noisy warning for the default path" "still warns on every personal repo"
else
  pass "No noisy warning for the default path"
fi

# 6.7 Missing default_account + unmatched repo → clean error
NODEFAULT_HOME="$TMPDIR_BASE/no-default"
mkdir -p "$NODEFAULT_HOME/.claude"
cat > "$NODEFAULT_HOME/.claude/account-guard.json" << 'JSON'
{
  "accounts": {
    "personal": {
      "email": "test@personal.com",
      "config_dir": "~/.claude-personal",
      "description": "Personal account"
    }
  },
  "repo_rules": []
}
JSON
mkdir -p "$NODEFAULT_HOME/repos/random-unknown"
OUTPUT=$(
  cd "$NODEFAULT_HOME/repos/random-unknown"
  PATH="$MOCK_BIN:$PATH" HOME="$NODEFAULT_HOME" \
  bash "$CCC" 2>&1 || true
)
if echo "$OUTPUT" | grep -q "no default_account is set"; then
  pass "Unmatched repo + no default_account → helpful error"
else
  fail "Unmatched repo + no default_account → helpful error" "$OUTPUT"
fi

# 6.8 A repo_rule pointing at an undefined account fails loudly
BADACCT_HOME="$TMPDIR_BASE/bad-account"
mkdir -p "$BADACCT_HOME/.claude" "$BADACCT_HOME/repos/anything"
cat > "$BADACCT_HOME/.claude/account-guard.json" << 'JSON'
{
  "default_account": "personal",
  "accounts": {
    "personal": { "email": "a@b.c", "config_dir": "~/.claude-personal", "description": "p" }
  },
  "repo_rules": [ { "match": "anything", "account": "ghost" } ]
}
JSON
OUTPUT=$(
  cd "$BADACCT_HOME/repos/anything"
  PATH="$MOCK_BIN:$PATH" HOME="$BADACCT_HOME" \
  bash "$CCC" 2>&1 || true
)
if echo "$OUTPUT" | grep -q "unknown account"; then
  pass "repo_rule with an undefined account → clear error"
else
  fail "repo_rule with an undefined account → clear error" "$OUTPUT"
fi

# ============================================================
# Section 7: Account mismatch + --force
# ============================================================
echo ""
echo "--- Account mismatch handling ---"

# 7.1 Wrong logged-in email in a matched repo → refuse
OUTPUT=$(CCC_TEST_AUTH_EMAIL="someone@else.com" run_ccc work-repo 2>&1 || true)
if echo "$OUTPUT" | grep -q "ACCOUNT MISMATCH"; then
  pass "Mismatched login refuses to launch"
else
  fail "Mismatched login refuses to launch" "$OUTPUT"
fi

# 7.2 --force overrides the mismatch and still launches
ARGLOG_FORCE="$TMPDIR_BASE/arglog-force"
OUTPUT=$(
  cd "$TMPDIR_BASE/repos/work-repo"
  CCC_TEST_ARGLOG="$ARGLOG_FORCE" \
  CCC_TEST_AUTH_EMAIL="someone@else.com" \
  PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" \
  bash "$CCC" --force 2>&1 || true
)
if echo "$OUTPUT" | grep -q "launching anyway"; then
  pass "--force overrides the mismatch"
else
  fail "--force overrides the mismatch" "$OUTPUT"
fi

# 7.3 --force is consumed by ccc and never reaches claude
FORCE_ARGS=$(grep -v 'auth status' "$ARGLOG_FORCE" 2>/dev/null || echo "")
if ! echo "$FORCE_ARGS" | grep -q -- '--force'; then
  pass "--force is stripped before exec claude"
else
  fail "--force is stripped before exec claude" "args: $FORCE_ARGS"
fi

# 7.4 Not logged in at all → points at --setup
OUTPUT=$(
  cd "$TMPDIR_BASE/repos/work-repo"
  CCC_TEST_LOGGED_OUT=1 \
  PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" \
  bash "$CCC" 2>&1 || true
)
if echo "$OUTPUT" | grep -q "Not logged into the work account"; then
  pass "Logged-out account points at ccc --setup"
else
  fail "Logged-out account points at ccc --setup" "$OUTPUT"
fi

# ============================================================
# Section 8: Non-git-repo behavior
# ============================================================
echo ""
echo "--- Non-git-repo path ---"

NOGIT_BIN="$TMPDIR_BASE/nogit-bin"
mkdir -p "$NOGIT_BIN"
cat > "$NOGIT_BIN/git" << 'MOCK'
#!/bin/bash
if [ "${1:-}" = "rev-parse" ]; then exit 128; fi
if [ "${1:-}" = "remote" ]; then exit 1; fi
/usr/bin/git "$@"
MOCK
chmod +x "$NOGIT_BIN/git"
cp "$MOCK_BIN/claude" "$NOGIT_BIN/claude"

OUTPUT=$(
  cd "$TMPDIR_BASE/repos/random-unknown"
  PATH="$NOGIT_BIN:$PATH" HOME="$TMPDIR_BASE" \
  bash "$CCC" 2>&1 || true
)
if echo "$OUTPUT" | grep -q "Not in a git repo"; then
  pass "Non-git directory shows info message"
else
  fail "Non-git directory shows info message" "$OUTPUT"
fi

# 8.2 A non-git directory still routes to the default account (not bare ~/.claude)
if echo "$OUTPUT" | grep -q "→ personal"; then
  pass "Non-git directory routes to default_account"
else
  fail "Non-git directory routes to default_account" "$OUTPUT"
fi

# ============================================================
# Section 9: --telegram flag + flag passthrough
# ============================================================
echo ""
echo "--- --telegram flag + flag passthrough ---"

OUTPUT=$(run_ccc my-project --telegram --status)
if echo "$OUTPUT" | grep -q "Repo:"; then
  pass "--telegram doesn't break --status"
else
  fail "--telegram doesn't break --status" "$OUTPUT"
fi

# 9.2 --telegram + prompt: -- separator keeps them apart
ARGLOG_CHAN="$TMPDIR_BASE/arglog-channels"
(
  cd "$TMPDIR_BASE/repos/my-project"
  CCC_TEST_ARGLOG="$ARGLOG_CHAN" \
  CCC_TEST_AUTH_EMAIL="test@personal.com" \
  PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" \
  bash "$CCC" --telegram "/example:cmd" 2>&1 >/dev/null
) || true
CLAUDE_ARGS=$(cat "$ARGLOG_CHAN" 2>/dev/null || echo "")
if echo "$CLAUDE_ARGS" | grep -q -- '--channels plugin:telegram@claude-plugins-official -- /example:cmd'; then
  pass "--telegram + prompt separated by -- (channels can't eat the prompt)"
else
  fail "--telegram + prompt separated by --" "args: $CLAUDE_ARGS"
fi

# 9.3 --resume <id>: flags must reach claude as flags, not trapped behind --
ARGLOG_RES="$TMPDIR_BASE/arglog-resume"
(
  cd "$TMPDIR_BASE/repos/my-project"
  CCC_TEST_ARGLOG="$ARGLOG_RES" \
  CCC_TEST_AUTH_EMAIL="test@personal.com" \
  PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" \
  bash "$CCC" --resume abc-123-fake 2>&1 >/dev/null
) || true
RESUME_ARGS=$(cat "$ARGLOG_RES" 2>/dev/null || echo "")
if echo "$RESUME_ARGS" | grep -q -- '--resume abc-123-fake' && ! echo "$RESUME_ARGS" | grep -q -- '-- --resume'; then
  pass "--resume <id> reaches claude as flag (not trapped behind --)"
else
  fail "--resume <id> reaches claude as flag" "args: $RESUME_ARGS"
fi

# 9.4 -c short flag: same invariant
ARGLOG_CONT="$TMPDIR_BASE/arglog-continue"
(
  cd "$TMPDIR_BASE/repos/my-project"
  CCC_TEST_ARGLOG="$ARGLOG_CONT" \
  CCC_TEST_AUTH_EMAIL="test@personal.com" \
  PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" \
  bash "$CCC" -c 2>&1 >/dev/null
) || true
CONT_ARGS=$(cat "$ARGLOG_CONT" 2>/dev/null || echo "")
if ! echo "$CONT_ARGS" | grep -q -- '-- -c'; then
  pass "-c short flag reaches claude as flag (not trapped behind --)"
else
  fail "-c short flag reaches claude as flag" "args: $CONT_ARGS"
fi

# ============================================================
# Section 10: Example config validation
# ============================================================
echo ""
echo "--- Example config ---"

EXAMPLE="$TEST_DIR/../account-guard.example.json"
if [ -f "$EXAMPLE" ]; then
  pass "account-guard.example.json exists"

  if python3 -c "import json; json.load(open('$EXAMPLE'))" 2>/dev/null; then
    pass "Example config is valid JSON"
  else
    fail "Example config is valid JSON" "parse error"
  fi

  if python3 -c "
import json
c = json.load(open('$EXAMPLE'))
assert 'accounts' in c, 'missing accounts'
assert 'repo_rules' in c, 'missing repo_rules'
for r in c['repo_rules']:
    assert ('match' in r) != ('remote' in r), f'rule needs exactly one of match/remote: {r}'
    assert 'account' in r, f'rule missing account: {r}'
    assert r['account'] in c['accounts'], f'unknown account: {r[\"account\"]}'
for name, a in c['accounts'].items():
    assert a.get('email'), f'account {name} needs an email'
    assert a.get('config_dir'), f'account {name} needs a config_dir'
if 'default_account' in c:
    assert c['default_account'] in c['accounts'], 'default_account must reference a named account'
" 2>/dev/null; then
    pass "Example config structure valid (accounts, rules, references, default)"
  else
    fail "Example config structure valid" "schema error"
  fi
else
  fail "account-guard.example.json exists" "not found at $EXAMPLE"
fi

# 10.2 The live config, if present, must satisfy the same schema
LIVE="$HOME/.claude/account-guard.json"
if [ -f "$LIVE" ]; then
  if python3 -c "
import json, os
c = json.load(open(os.path.expanduser('$LIVE')))
for r in c.get('repo_rules', []):
    assert ('match' in r) != ('remote' in r), f'rule needs exactly one of match/remote: {r}'
    assert r['account'] in c['accounts'], f'unknown account: {r[\"account\"]}'
if 'default_account' in c:
    assert c['default_account'] in c['accounts'], 'default_account must reference a named account'
" 2>/dev/null; then
    pass "Live ~/.claude/account-guard.json satisfies the schema"
  else
    fail "Live ~/.claude/account-guard.json satisfies the schema" "schema error"
  fi
else
  pass "No live config to validate (skipped)"
fi

# ============================================================
# Section 11: Missing config handling
# ============================================================
echo ""
echo "--- Missing config handling ---"

NOCONFIG_HOME="$TMPDIR_BASE/no-config"
mkdir -p "$NOCONFIG_HOME/repos/anything"
OUTPUT=$(
  cd "$NOCONFIG_HOME/repos/anything"
  PATH="$MOCK_BIN:$PATH" HOME="$NOCONFIG_HOME" \
  bash "$CCC" 2>&1 || true
)
if echo "$OUTPUT" | grep -q "No account-guard config"; then
  pass "Missing config shows helpful error"
else
  fail "Missing config shows helpful error" "$OUTPUT"
fi

# ============================================================
# Section 12: GitHub + git isolation
# ============================================================
echo ""
echo "--- GitHub + git per-account isolation ---"

# 12.1 GH_CONFIG_DIR is exported from the script
if grep -q 'export GH_CONFIG_DIR=' "$CCC"; then
  pass "Script exports GH_CONFIG_DIR"
else
  fail "Script exports GH_CONFIG_DIR" "not found in script"
fi

# 12.2 GIT_CONFIG_GLOBAL is exported from the script
if grep -q 'export GIT_CONFIG_GLOBAL=' "$CCC"; then
  pass "Script exports GIT_CONFIG_GLOBAL"
else
  fail "Script exports GIT_CONFIG_GLOBAL" "not found in script"
fi

# 12.3 XDG_CONFIG_HOME is exported from the script for modern Wrangler
if grep -q 'export XDG_CONFIG_HOME=' "$CCC"; then
  pass "Script exports XDG_CONFIG_HOME"
else
  fail "Script exports XDG_CONFIG_HOME" "not found in script"
fi

# 12.4 Running ccc in a known repo creates the per-account gh dir
ISOLATE_HOME="$TMPDIR_BASE/iso-home"
mkdir -p "$ISOLATE_HOME/.claude" "$ISOLATE_HOME/.claude-personal" \
         "$ISOLATE_HOME/repos/my-project"
cp "$TMPDIR_BASE/.claude/account-guard.json" "$ISOLATE_HOME/.claude/"
ENVLOG="$TMPDIR_BASE/isolate-env"
(
  cd "$ISOLATE_HOME/repos/my-project"
  CCC_TEST_ARGLOG="/dev/null" \
  CCC_TEST_ENVLOG="$ENVLOG" \
  CCC_TEST_AUTH_EMAIL="test@personal.com" \
  PATH="$MOCK_BIN:$PATH" HOME="$ISOLATE_HOME" \
  bash "$CCC" 2>&1 >/dev/null
) || true
if [ -d "$ISOLATE_HOME/.claude-personal/gh" ]; then
  pass "Per-account gh dir created at \$config_dir/gh"
else
  fail "Per-account gh dir created" "$ISOLATE_HOME/.claude-personal/gh missing"
fi

# 12.5 Running ccc exports per-account auth env vars
if grep -q "^GH_CONFIG_DIR=$ISOLATE_HOME/.claude-personal/gh$" "$ENVLOG" \
  && grep -q "^GIT_CONFIG_GLOBAL=$ISOLATE_HOME/.claude-personal/gitconfig$" "$ENVLOG" \
  && grep -q "^WRANGLER_HOME=$ISOLATE_HOME/.claude-personal/wrangler$" "$ENVLOG" \
  && grep -q "^XDG_CONFIG_HOME=$ISOLATE_HOME/.claude-personal/xdg$" "$ENVLOG"; then
  pass "Per-account env vars exported to claude session"
else
  fail "Per-account env vars exported to claude session" \
    "env: $(cat "$ENVLOG" 2>/dev/null)"
fi

# 12.6 Running ccc creates the per-account gitconfig with the include stanza
if [ -f "$ISOLATE_HOME/.claude-personal/gitconfig" ]; then
  pass "Per-account gitconfig file created"
  if grep -q 'path = ~/.gitconfig' "$ISOLATE_HOME/.claude-personal/gitconfig"; then
    pass "Per-account gitconfig includes ~/.gitconfig as base"
  else
    fail "Per-account gitconfig includes ~/.gitconfig" \
      "content: $(cat "$ISOLATE_HOME/.claude-personal/gitconfig")"
  fi
else
  fail "Per-account gitconfig file created" "missing"
fi

# 12.7 Per-account gitconfig clears shared helpers and forces gh for GitHub HTTPS
if grep -q '\[credential "https://github.com"\]' "$ISOLATE_HOME/.claude-personal/gitconfig" \
  && grep -q 'helper = !gh auth git-credential' "$ISOLATE_HOME/.claude-personal/gitconfig"; then
  pass "Per-account gitconfig forces gh credential helper for GitHub hosts"
else
  fail "Per-account gitconfig forces gh credential helper" \
    "content: $(cat "$ISOLATE_HOME/.claude-personal/gitconfig")"
fi

# 12.8 Existing per-account gitconfig is NOT clobbered
USER_CONTENT="# user-edited content"
echo "$USER_CONTENT" > "$ISOLATE_HOME/.claude-personal/gitconfig"
(
  cd "$ISOLATE_HOME/repos/my-project"
  CCC_TEST_ARGLOG="/dev/null" \
  CCC_TEST_AUTH_EMAIL="test@personal.com" \
  PATH="$MOCK_BIN:$PATH" HOME="$ISOLATE_HOME" \
  bash "$CCC" 2>&1 >/dev/null
) || true
if grep -q "$USER_CONTENT" "$ISOLATE_HOME/.claude-personal/gitconfig"; then
  pass "Existing per-account gitconfig is preserved (no clobber)"
else
  fail "Existing per-account gitconfig preserved" \
    "content lost: $(cat "$ISOLATE_HOME/.claude-personal/gitconfig")"
fi

# ============================================================
# Section 13: Dependencies
# ============================================================
echo ""
echo "--- Dependencies ---"
for CMD in python3 git; do
  if command -v "$CMD" &>/dev/null; then
    pass "$CMD available"
  else
    fail "$CMD available" "not in PATH"
  fi
done


# ============================================================
# Stability: no silent exits, helpers, doctor
# ============================================================
echo ""
echo "--- Stability ---"

for f in route.py auth_email.py setup.sh doctor.sh; do
  if [ -f "$TEST_DIR/../lib/$f" ]; then pass "lib/$f present"; else fail "lib/$f present" "missing"; fi
done

# Reached through a symlink (how ~/.local/bin/ccc works) the helpers are still found
ln -sf "$CCC" "$TMPDIR_BASE/ccc-link"
OUTPUT=$(cd "$TMPDIR_BASE/repos/my-project" && CCC_TEST_AUTH_EMAIL="test@personal.com" PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" bash "$TMPDIR_BASE/ccc-link" --status 2>&1 || true)
if echo "$OUTPUT" | grep -q "personal" && ! echo "$OUTPUT" | grep -q "unbound"; then
  pass "Works when called through a symlink"
else
  fail "Works when called through a symlink" "$OUTPUT"
fi

# Not logged in → clear message, and no 'stopped unexpectedly' noise
OUTPUT=$(cd "$TMPDIR_BASE/repos/my-project" && CCC_TEST_AUTH_EMAIL="" PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" bash "$CCC" 2>&1 || true)
if echo "$OUTPUT" | grep -q "Not logged into" && ! echo "$OUTPUT" | grep -q "unexpectedly"; then
  pass "Not logged in: clear message, no trap noise"
else
  fail "Not logged in: clear message" "$OUTPUT"
fi

# Hung `claude auth status` → times out with a message instead of freezing
START=$(date +%s)
OUTPUT=$(CCC_TEST_AUTH_SLEEP=5 CCC_AUTH_TIMEOUT=1 run_ccc my-project || true)
ELAPSED=$(( $(date +%s) - START ))
if echo "$OUTPUT" | grep -q "did not answer" && [ "$ELAPSED" -lt 5 ]; then
  pass "Hung auth check times out with a message (${ELAPSED}s)"
else
  fail "Hung auth check times out" "elapsed=${ELAPSED}s out=$OUTPUT"
fi

# claude missing from PATH → says so
OUTPUT=$(cd "$TMPDIR_BASE/repos/my-project" && PATH="/usr/bin:/bin" HOME="$TMPDIR_BASE" bash "$CCC" 2>&1 || true)
if echo "$OUTPUT" | grep -q "not on PATH"; then
  pass "Missing claude binary is reported"
else
  fail "Missing claude binary is reported" "$OUTPUT"
fi

# Unexpected failure → the ERR trap names the line instead of exiting silently
if grep -q "trap .*stopped unexpectedly.*ERR" "$CCC" && grep -q "^set -E" "$CCC"; then
  pass "ERR trap reports unexpected failures"
else
  fail "ERR trap reports unexpected failures" "trap or set -E missing"
fi

# --doctor: valid config + matching login → per-account report
OUTPUT=$(CCC_TEST_AUTH_EMAIL="test@personal.com" run_ccc my-project --doctor || true)
if echo "$OUTPUT" | grep -q "Account personal" && echo "$OUTPUT" | grep -q "Account work" && echo "$OUTPUT" | grep -q "Config is valid"; then
  pass "--doctor reports config and every account"
else
  fail "--doctor reports config and every account" "$OUTPUT"
fi
if echo "$OUTPUT" | grep -q "logged in as test@personal.com, expected test@work.example"; then
  pass "--doctor flags a login on the wrong email"
else
  fail "--doctor flags a login on the wrong email" "$OUTPUT"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
