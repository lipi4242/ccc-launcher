# ccc — Claude Code launcher

A small bash wrapper around `claude` that:

- **Runs multiple Claude accounts side-by-side.** Each account has its own
  config dir, so you can have separate tmux panes signed into different
  accounts without re-logging in.
- **Routes each repo to the right account.** Match a substring of the cwd
  to an account name; everything unmatched falls through to your
  `default_account` (typically `personal`).
- **Always launches with `--dangerously-skip-permissions`,** 1M context,
  Opus 4.7, with compaction at 500K tokens.
- **Refuses to launch on an account mismatch** (e.g. you're sitting in a
  work repo but logged into your personal account). Override with `--force`.

The launcher itself never sees your tokens — it just sets `CLAUDE_CONFIG_DIR`
before invoking `claude`. Auth still happens via `claude auth login` per
account.

## Install

```bash
git clone <this-repo-url> ~/code/ccc-launcher
cd ~/code/ccc-launcher
bash install.sh
```

`install.sh`:

1. Symlinks `ccc` into `~/.local/bin/`.
2. Copies `account-guard.example.json` → `~/.claude/account-guard.json`
   (only if you don't have one yet).
3. Warns you if `~/.local/bin` isn't on your PATH.

## Configure

Open `~/.claude/account-guard.json` and edit two sections.

### `accounts`

Each account is a name → `{email, config_dir, description}`. The launcher
will run `claude` with `CLAUDE_CONFIG_DIR=<config_dir>` for that account, so
each entry keeps its own auth token.

```json
{
  "personal": {
    "email": "you@example.com",
    "config_dir": "~/.claude-personal",
    "description": "Personal — catch-all"
  },
  "acme": {
    "email": "you@acme.com",
    "config_dir": "~/.claude-acme",
    "description": "Acme Corp work"
  }
}
```

Add as many as you need. The names are arbitrary identifiers — pick
whatever helps you read the `--status` output.

The optional `testcase` account (with `email: null`, `config_dir: null`)
is a special path: it doesn't OAuth, it picks up `ANTHROPIC_API_KEY` /
`CLAUDE_API_KEY` from your environment (e.g. via direnv). Delete it if
you don't use API-key workflows.

### `repo_rules`

An ordered list. Each rule is `{match, account}`. `match` is a substring
checked against the **full cwd path**. The first matching rule wins —
which means more specific rules should appear above more general ones.

```json
"repo_rules": [
  { "match": "testcases/", "account": "testcase" },
  { "match": "acme-internal", "account": "acme" },
  { "match": "client-projects/acme/", "account": "acme" }
]
```

### `default_account`

The account used when no `repo_rules` entry matches. Convention is
`"personal"` — that's where you'll be logged in for everything that isn't
explicit work.

```json
"default_account": "personal"
```

If you omit `default_account`, the launcher refuses to start in an
unmatched repo and tells you to add a rule. Use that if you'd rather
fail loudly than silently route to the wrong account.

## First-time login

```bash
ccc --setup
```

Walks through each account in your config (skipping the `testcase`-style
ones automatically) and runs `claude auth login` against the right
config dir. Each account needs this once.

## Daily use

```bash
cd ~/code/some-repo
ccc                       # picks the right account, launches claude
ccc --status              # show which account this repo maps to
ccc --resume <session>    # pass through to claude
ccc /your:slash-command   # passes a slash command as the prompt
ccc --telegram            # adds the Telegram channel plugin
ccc --force               # ignore account-mismatch error and launch anyway
```

Inside tmux: each pane can be in a different repo and therefore a
different account, all signed in simultaneously.

## GitHub accounts (per-account `gh` + `git`)

Same multi-account pattern: each account gets its own `gh` auth token and its
own `git` config. The launcher exports two extra env vars at exec time:

- `GH_CONFIG_DIR=<config_dir>/gh` — `gh` CLI stores its host/token here.
- `GIT_CONFIG_GLOBAL=<config_dir>/gitconfig` — `git` reads this instead of
  `~/.gitconfig`. The file is auto-created on first launch with an
  `[include] path = ~/.gitconfig` stanza, so your global aliases/prefs still
  apply; you add per-account overrides below.

### First-time GitHub login

`ccc --setup` walks each account through `claude auth login`, and if `gh`
is installed (`brew install gh`), also offers to run `gh auth login` +
`gh auth setup-git` against the account's `GH_CONFIG_DIR`. Once per
account.

After that, inside any matched repo:

```bash
gh repo view              # uses the right account
git push                  # HTTPS push uses the right token (via gh credential helper)
git commit                # signs with the per-account user.email
```

### Per-account git identity

Edit `<config_dir>/gitconfig` to set your work email + signing key:

```ini
[user]
    email = you@work.example
    signingkey = <fingerprint>

[include]
    path = ~/.gitconfig
```

The auto-created file already has the `[include]` line — just add your
overrides above it (later `[user]` entries win).

### SSH-based push/pull

The env vars don't switch SSH keys. If you push via `git@github.com:…`, do
the standard `~/.ssh/config` trick once:

```
Host github-personal
    HostName github.com
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes

Host github-work
    HostName github.com
    IdentityFile ~/.ssh/work_ed25519
    IdentitiesOnly yes
```

Then per work repo, set the remote to `git@github-work:org/repo.git`.
Alternatively, set `core.sshCommand = ssh -i ~/.ssh/work_ed25519` in the
per-account `gitconfig` to force a key without rewriting remote URLs.

## Optional: per-account Cloudflare env

If you keep a file at `<account_config_dir>/cloudflare.env`, the
launcher will source it before exec'ing claude. Useful when you have
separate Cloudflare accounts per workspace:

```bash
# ~/.claude-acme/cloudflare.env
CLOUDFLARE_API_TOKEN=...
CLOUDFLARE_ACCOUNT_ID=...
```

The launcher also points `WRANGLER_HOME` at `<account_config_dir>/wrangler/`
so `wrangler login` keeps its OAuth token under the same account.

## Tests

```bash
bash tests/test_ccc.sh
```

Pure mock — no real `claude` invocations, no network. Validates syntax,
flag handling, account resolution, mismatch detection, the
default-account fallback, and the missing-config error.

## Notes

- `--dangerously-skip-permissions` is baked into every code path.
  This is a launcher for people who've already decided they want that
  posture; if you don't, edit the `exec claude` lines.
- The `account-guard.json` is read fresh on every invocation — no
  caching, edit and run again.
- Tested on macOS with bash 3.2 and zsh as the parent shell.
