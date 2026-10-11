# ADR 0008 — Conversations are append-only; a full conversation ends instead of being trimmed

- **Status:** proposed (the owner has not confirmed it yet)
- **Date:** 2026-10-11
- **Proposed by:** research, v1 planning

## Context

On Sonnet 5.5 and Haiku 5.5, editing or deleting earlier messages, the system
prompt or the tools returns 400 on accounts created on or after 2026-08-31
(preserved thinking); removing every thinking block is allowed. Prompt caching
matches on the exact prefix (tools, then system, then messages), and the
minimum cacheable prompt is 512 tokens.

## Decision

- The system prompt and the tool definitions stay constant, byte for byte: no
  timestamps or other changing text.
- Assistant turns, including thinking blocks, are sent back exactly as
  received.
- History is never trimmed. At the turn cap or the idle reset, the
  conversation ends and the next one starts fresh.

## Trade-off

- **Gain:** no 400s from edited history, a warm cache, simple code.
- **Cost:** a long conversation ends abruptly at the cap; nothing carries over
  (memory is on the Later list).

## Alternatives

- **Strip all thinking blocks, then a sliding window:** allowed, but it loses
  the reasoning and breaks the cache on every turn. Not chosen.
- **Summary compaction:** keeps context, but costs an extra call and adds
  latency. Kept for later.
