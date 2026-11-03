#!/usr/bin/env python3
"""Print the email `claude` is logged in as for one config dir.

Usage: auth_email.py <config_dir>
Exit codes: 0 = logged in (email on stdout), 2 = not logged in,
            3 = `claude auth status` timed out or returned garbage.
The timeout (CCC_AUTH_TIMEOUT, default 20 s) keeps a hung CLI from
freezing the launcher with no message.
"""
import json
import os
import subprocess
import sys

config_dir = sys.argv[1]
timeout = float(os.environ.get("CCC_AUTH_TIMEOUT", "20"))
env = dict(os.environ, CLAUDE_CONFIG_DIR=config_dir)

try:
    out = subprocess.run(
        ["claude", "auth", "status", "--json"],
        env=env, stdin=subprocess.DEVNULL, capture_output=True,
        text=True, timeout=timeout,
    ).stdout
except subprocess.TimeoutExpired:
    sys.stderr.write("`claude auth status` did not answer in %gs\n" % timeout)
    sys.exit(3)

try:
    data = json.loads(out)
except ValueError:
    sys.stderr.write("`claude auth status --json` returned no JSON: %r\n" % out[:200])
    sys.exit(3)

email = data.get("email") or ""
if not email:
    sys.exit(2)
print(email)
