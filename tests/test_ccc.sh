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
# Handle auth status --json
if [[ "$*" == *"auth status"* ]] && [[ "$*" == *"--json"* ]]; then
  echo "{\"email\":\"${CCC_TEST_AUTH_EMAIL:-test@personal.com}\"}"
  exit 0
fi
exit 0
MOCK
chmod +x "$MOCK_BIN/claude"

# Mock git: returns configurable repo root
cat > "$MOCK_BIN/git" << 'MOCK'
#!/bin/bash
if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--show-toplevel" ]; then
  if [ "${CCC_TEST_NO_GIT:-}" = "1" ]; then
    exit 128
  fi
  # Return the cwd as the repo root
  pwd
  exit 0
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
    },
    "testcase": {
      "email": null,
      "config_dir": null,
      "description": "Testcase — direnv API key"
    }
  },
  "repo_rules": [
    { "match": "testcases/", "account": "testcase" },
    { "match": "my-project", "account": "personal" },
    { "match": "work-repo", "account": "work" }
  ]
}
JSON

# Create fake repo dirs (ccc matches against pwd)
mkdir -p "$TMPDIR_BASE/repos/my-project"
mkdir -p "$TMPDIR_BASE/repos/work-repo"
mkdir -p "$TMPDIR_BASE/repos/testcases/hf-999"
mkdir -p "$TMPDIR_BASE/repos/random-unknown"
mkdir -p "$TMPDIR_BASE/.claude-personal"
mkdir -p "$TMPDIR_BASE/.claude-work"

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
# Section 4: Session config (single mode — always 1M Opus)
# ============================================================
echo ""
echo "--- Session config ---"

# 4.1 Default banner shows 1M / Opus 4.7
OUTPUT=$(run_ccc my-project --status)
if echo "$OUTPUT" | grep -q "1M context · Opus 4.7"; then
  pass "Banner shows '1M context · Opus 4.7'"
else
  fail "Banner shows '1M context · Opus 4.7'" "$(echo "$OUTPUT" | head -1)"
fi

# 4.2 No 200K / routine-mode artifacts in script
if grep -q "ROUTINE MODE\|CLAUDE_CODE_DISABLE_1M_CONTEXT\|CLAUDE_CODE_EFFORT_LEVEL=medium" "$CCC"; then
  fail "Routine-mode artifacts removed from script" "found legacy strings"
else
  pass "Routine-mode artifacts removed from script"
fi

# 4.3 --orch / --orchestrator silently accepted (no-op, doesn't break flow)
OUTPUT=$(run_ccc my-project --orch --status)
if echo "$OUTPUT" | grep -q "Repo:"; then
  pass "--orch silently accepted (deprecated no-op)"
else
  fail "--orch silently accepted" "$(echo "$OUTPUT" | head -3)"
fi
OUTPUT=$(run_ccc my-project --orchestrator --status)
if echo "$OUTPUT" | grep -q "Repo:"; then
  pass "--orchestrator (long form) silently accepted"
else
  fail "--orchestrator silently accepted" "$(echo "$OUTPUT" | head -3)"
fi

# 4.4 --model opus included in EXTRA_FLAGS
ARGLOG="$TMPDIR_BASE/arglog-model"
(
  cd "$TMPDIR_BASE/repos/my-project"
  CCC_TEST_ARGLOG="$ARGLOG" \
  CCC_TEST_AUTH_EMAIL="test@personal.com" \
  PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" \
  bash "$CCC" 2>&1 >/dev/null
) || true
if grep -q -- "--model opus" "$ARGLOG" 2>/dev/null; then
  pass "claude invoked with --model opus"
else
  fail "claude invoked with --model opus" "args: $(cat $ARGLOG 2>/dev/null)"
fi

# ============================================================
# Section 5: --status output completeness
# ============================================================
echo ""
echo "--- --status output ---"
OUTPUT=$(run_ccc my-project --status)
for FIELD in "Repo:" "Account:" "Config:" "Desc:"; do
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

# 6.1 Personal repo
OUTPUT=$(run_ccc my-project --status)
if echo "$OUTPUT" | grep -q "personal"; then
  pass "my-project → personal account"
else
  fail "my-project → personal account" "$OUTPUT"
fi

# 6.2 Work repo
OUTPUT=$(CCC_TEST_AUTH_EMAIL="test@work.example" run_ccc work-repo --status)
if echo "$OUTPUT" | grep -q "work"; then
  pass "work-repo → work account"
else
  fail "work-repo → work account" "$OUTPUT"
fi

# 6.3 Unknown repo resolves as unknown in --status
OUTPUT=$(run_ccc random-unknown --status)
if echo "$OUTPUT" | grep -q "Account:.*unknown"; then
  pass "Unknown repo shows 'unknown' in --status"
else
  fail "Unknown repo shows 'unknown' in --status" "$OUTPUT"
fi

# 6.4 Unknown repo shows warning on normal launch (not --status)
OUTPUT=$(run_ccc random-unknown 2>&1 || true)
if echo "$OUTPUT" | grep -q "not in account-guard"; then
  pass "Unknown repo launch shows warning"
else
  fail "Unknown repo launch shows warning" "$OUTPUT"
fi

# 6.5 Unknown repo defaults to default_account (= personal in test config)
if echo "$OUTPUT" | grep -q "Defaulting to personal"; then
  pass "Unknown repo defaults to default_account"
else
  fail "Unknown repo defaults to default_account" "$OUTPUT"
fi

# 6.6 Testcase match via python
ACCT=$(python3 -c "
import json, os
cfg = json.load(open('$TMPDIR_BASE/.claude/account-guard.json'))
cwd = '$TMPDIR_BASE/repos/testcases/hf-999'
for rule in cfg.get('repo_rules', []):
    if rule['match'] in cwd:
        print(rule['account'])
        exit(0)
print('unknown')
")
if [ "$ACCT" = "testcase" ]; then
  pass "testcases/ path → testcase account"
else
  fail "testcases/ path → testcase account" "got: $ACCT"
fi

# 6.7 Missing default_account + unknown repo → clean error
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
if echo "$OUTPUT" | grep -q "no default_account set"; then
  pass "Unknown repo + no default_account → helpful error"
else
  fail "Unknown repo + no default_account → helpful error" "$OUTPUT"
fi

# ============================================================
# Section 7: Testcase repo behavior
# ============================================================
echo ""
echo "--- Testcase repo path ---"

# 7.1 With API key set → succeeds
OUTPUT=$(
  cd "$TMPDIR_BASE/repos/testcases/hf-999"
  ANTHROPIC_API_KEY="sk-test-fake" \
  PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" \
  bash "$CCC" 2>&1 || true
)
if echo "$OUTPUT" | grep -q "testcase (direnv API key)"; then
  pass "Testcase with API key shows success"
else
  fail "Testcase with API key shows success" "$OUTPUT"
fi

# 7.2 Without API key → fails with helpful message
OUTPUT=$(
  cd "$TMPDIR_BASE/repos/testcases/hf-999"
  unset ANTHROPIC_API_KEY 2>/dev/null || true
  unset CLAUDE_API_KEY 2>/dev/null || true
  PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" \
  bash "$CCC" 2>&1 || true
)
if echo "$OUTPUT" | grep -q "no API key set"; then
  pass "Testcase without API key shows error"
else
  fail "Testcase without API key shows error" "$OUTPUT"
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
if echo "$CLAUDE_ARGS" | grep -q -- '-- /example:cmd'; then
  pass "--telegram + prompt separated by -- (no arg eating)"
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
    assert 'match' in r, f'rule missing match: {r}'
    assert 'account' in r, f'rule missing account: {r}'
    assert r['account'] in c['accounts'], f'unknown account: {r[\"account\"]}'
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

# 12.3 Running ccc in a known repo creates the per-account gh dir
ISOLATE_HOME="$TMPDIR_BASE/iso-home"
mkdir -p "$ISOLATE_HOME/.claude" "$ISOLATE_HOME/.claude-personal" \
         "$ISOLATE_HOME/repos/my-project"
cp "$TMPDIR_BASE/.claude/account-guard.json" "$ISOLATE_HOME/.claude/"
(
  cd "$ISOLATE_HOME/repos/my-project"
  CCC_TEST_ARGLOG="/dev/null" \
  CCC_TEST_AUTH_EMAIL="test@personal.com" \
  PATH="$MOCK_BIN:$PATH" HOME="$ISOLATE_HOME" \
  bash "$CCC" 2>&1 >/dev/null
) || true
if [ -d "$ISOLATE_HOME/.claude-personal/gh" ]; then
  pass "Per-account gh dir created at \$config_dir/gh"
else
  fail "Per-account gh dir created" "$ISOLATE_HOME/.claude-personal/gh missing"
fi

# 12.4 Running ccc creates the per-account gitconfig with the include stanza
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

# 12.5 Existing per-account gitconfig is NOT clobbered
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

# --- Summary ---
echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
