#!/usr/bin/env python3
"""Resolve which account a directory belongs to.

Inputs come from env: CCC_GUARD (config path), CCC_CWD, CCC_REMOTE.
Prints one line: source|name|email|config_dir|description
where source is rule, default or none. Exits 1 on a broken config.
"""
import json, os, sys

try:
    cfg = json.load(open(os.environ['CCC_GUARD']))
except Exception as exc:
    sys.stderr.write("account-guard.json is not readable: %s\n" % exc)
    sys.exit(1)

cwd = os.environ['CCC_CWD']
remote = os.environ.get('CCC_REMOTE', '')
accounts = cfg.get('accounts', {})

# Match remote rules against both the raw URL and a slash-normalised copy, so
# one rule covers both remote forms:
#   https://github.com/Org/repo.git   → matches "github.com/Org/" as written
#   git@github.com:Org/repo.git       → matches it via the normalised copy
remote_forms = [remote.lower(), remote.replace(':', '/').lower()] if remote else []


def emit(status, name):
    acct = accounts.get(name, {})
    config_dir = acct.get('config_dir') or ''
    if config_dir:
        config_dir = os.path.expanduser(config_dir)
    print('|'.join([status, name, acct.get('email') or '', config_dir,
                    acct.get('description') or '']))


for rule in cfg.get('repo_rules', []):
    name = rule.get('account')
    if name not in accounts:
        sys.stderr.write("repo_rule points at unknown account %r\n" % name)
        sys.exit(1)
    if 'remote' in rule:
        needle = rule['remote'].lower()
        hit = any(needle in form for form in remote_forms)
    elif 'match' in rule:
        hit = rule['match'] in cwd
    else:
        sys.stderr.write("repo_rule needs a 'remote' or 'match' key: %r\n" % rule)
        sys.exit(1)
    if hit:
        emit('rule', name)
        sys.exit(0)

fallback = cfg.get('default_account')
if fallback and fallback in accounts:
    emit('default', fallback)
    sys.exit(0)

print('none||||')
