# ADR 0005 — Typed, allowlisted tools and the API key in the Keychain

- **Status:** accepted
- **Date:** 2026-10-11
- **Decided by:** the owner
- **Proposed by:** research, after the platform review

## Context

Claude decides which Mac action to take, and everything the owner says, and
later screen or mail content, reaches it as input. A generic `run_shell` or
`run_applescript` tool would let the model do anything the owner can do:
`osascript` alone can run shell commands, send mail and type keys. The
Anthropic API key bills the owner's account.

## Decision

- Claude gets **typed tools only**, each with a strict JSON schema
  (`strict: true`): for v1, `open_app` (from an allowlist of installed apps)
  and the timer tools. There is no generic shell, AppleScript or `osascript`
  tool.
- Uriel's own code **re-validates every tool argument** before acting, and
  logs every tool call.
- Tools that send, delete, spend or act on the screen (all later) need a spoken
  and on-screen confirmation that the model cannot give itself.
- The **API key lives in the Keychain**, never in an environment variable, a
  file in the repo, or a log line.

## Trade-off

- **Gain:** the worst a confused or manipulated model can do is open an allowed
  app or set a timer; the key cannot leak through child processes or logs.
- **Cost:** every new ability is a new tool with its own schema and checks, so
  growth is slower than with one generic tool.

## Alternatives

- **A generic shell or AppleScript tool with confirmation for each call:**
  flexible, but every confirmation becomes a rubber stamp. Not chosen.
- **The key in an environment variable or `.env`:** simpler, but it leaks to
  every child process. Not chosen.
