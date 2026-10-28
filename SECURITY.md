# Security policy

## Supported versions

Only the latest release receives security fixes.

## Reporting a vulnerability

Please report privately through GitHub: open this repository's **Security** tab and choose **Report a vulnerability**. Please don't open a public issue for a security problem.

Include what you found, how to reproduce it, and the version or commit you tested. This is a one-person project, so responses are best effort; you will get an acknowledgement as soon as the report is seen, and a fix or an explanation after that.

## Scope

In scope: anything in this repository, in particular

- how the Claude Code OAuth token is handled (it must only ever be read from the Keychain, sent to the usage endpoint, and never logged, stored or sent anywhere else);
- the files Clauwise writes (`~/.clauwise/`, `~/Library/Logs/Clauwise.log`, the optional `statusLine` entry in `~/.claude/settings.json` and its backup);
- the `Clauwise statusline` command;
- `build.sh`.

Out of scope:

- Claude, Claude Code and Anthropic's API themselves: please report those to Anthropic.
- Problems that need an attacker who already controls your macOS user account.
