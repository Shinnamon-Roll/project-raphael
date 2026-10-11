# ADR 0010 — Chat model: Sonnet 5.5 low with between_tools; Uriel confirms tool calls herself

- **Status:** accepted
- **Date:** 2026-10-12
- **Decided by:** the owner ("กูมีงบเดือนละ50$ เอาดีที่สุด", and the local confirmation)
- **Proposed by:** the main session, from the latency spike (`docs/spikes/latency.md`)

ADR 0009 is kept for the wake-word engine (Phase 0 step 7).

## Context

The latency spike measured five configurations in English and in Thai. None reached the owner's target of 1.5 s from the end of speech to the first spoken word, because the first token takes about 0.9–1.3 s whatever the model. A tool turn takes two requests, so "open Safari" took about 2.7–3.0 s to the first sentence. In the owner's blind rating of the Thai answers, the Sonnet configurations beat Haiku. Sonnet `low` with `between_tools` scored highest, 3.50 of 5, and it had no slow tail on tool calls. The owner's API budget is $50 a month.

## Decision

- **Chat model:** `claude-sonnet-5-5`, `output_config.effort: "low"`, `thinking: {"type": "between_tools"}`. It stays one constant (ADR 0002).
- **Tool turns:** when a tool succeeds, Uriel speaks a fixed confirmation line in the persona's style at once, such as "เปิด Safari แล้วค่ะ". She still sends the `tool_result` and keeps Claude's reply in the history (ADR 0008), but does not speak a reply that only confirms the action again.

## Trade-off

- **Gain:**
  - the answers the owner rated best;
  - tool calls without the stall seen on Sonnet `low`;
  - "open <app>" and timers spoken about 2 s sooner;
  - about $15 a month at 100 turns a day, within the budget.
- **Cost:**
  - chat reaches the first spoken word about 2.6 s after the owner stops speaking, about 0.5 s slower than Sonnet `low`;
  - effort cannot change within a conversation;
  - the words after a tool are fixed lines, not Claude's.
  - Phase 1 step 6 has to decide when Claude's reply after a tool says something new and should be spoken after all.

## Alternatives

- **Sonnet `low`:** the fastest chat (about 2.1 s to the first spoken word), rated 3.00, but a tool call sometimes stalled for about 9 s. Not chosen.
- **Sonnet `medium`:** the steadiest tool calls, rated 2.83. Not chosen.
- **Haiku 5.5:** under $1 a month, rated 1.83–2.50. Not chosen.
- **Opus 5.5:** not measured. It is about twice Sonnet's price (about $30 a month at the same use), and its latency is listed as moderate. Kept as a later test if the owner wants a stronger model.
