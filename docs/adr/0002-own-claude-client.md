# ADR 0002 — Our own Claude API client over HTTPS and SSE

- **Status:** accepted
- **Date:** 2026-10-11
- **Decided by:** the owner (follows from ADR 0001)

## Context

Uriel chats like Claude and turns spoken requests into Mac actions through
tool use. Anthropic's SDKs cover Python, TypeScript, C#, Go, Java, PHP and Ruby,
not Swift. The Messages API is plain HTTPS with server-sent events for
streaming.

## Decision

Write a small Claude client in Swift on `URLSession`: the Messages API with
streaming, tool use with `tool_choice: auto` and `strict: true` tools, and
prompt caching for the system prompt. Speech output starts on the first
complete sentence of the stream. The model ID is one constant, so the chat
model can change without touching the rest (the choice is an open question in
`CLAUDE.md`).

## Trade-off

- **Gain:** no runtime besides the app; full control over streaming, so the
  first sentence is spoken as soon as it arrives; no dependency to keep up to
  date.
- **Cost:** we maintain the request and event types and the tool loop by hand,
  and follow API changes ourselves. Forced tool use (`tool_choice` `any` or
  `tool`) returns 400 on Sonnet 5.5, Opus 5.5 and Fable 5.1, so the client
  never relies on it.

## Alternatives

- **A community Swift SDK:** less code, but an unofficial dependency that lags
  the API. Not chosen.
- **A Python or Bun sidecar with the official SDK:** see ADR 0001. Not chosen.
