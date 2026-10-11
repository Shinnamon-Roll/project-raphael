# Latency spike (Phase 0 step 6)

Settles the chat model and its effort. Run on 2026-10-12 from the owner's home network, with the spike in `Spikes/Latency`. Raw results stay in the git-ignored `Spikes/Latency/results/`:

- `2026-10-12-003611-run`: English, 1 cold and 10 warm rounds;
- `2026-10-12-021432-run`: Thai, 1 cold and 3 warm rounds, with the Kanade persona of `docs/persona.md`.

**Decision (the owner, 2026-10-12): Sonnet 5.5, `low` effort, thinking `between_tools`, and tool turns confirmed by Uriel herself** (ADR 0010).

## What was measured

Five configurations:

- Haiku 5.5 `low`;
- Haiku 5.5 `low` with thinking disabled;
- Sonnet 5.5 `low`;
- Sonnet 5.5 `low` with `between_tools`;
- Sonnet 5.5 `medium`.

Twelve utterances:

- 6 chats with a follow-up;
- 3 "open <app>";
- 3 timers.

Times run from the request to the first complete sentence, p50 / p95. Warm means the prompt cache was already filled. The owner's target was at most 1.5 s from the end of speech to the first spoken word. The 0.8 s silence timer comes first, so the API and the voice have 0.7 s.

## Results

Neither run had a failed request, and every configuration called the right tool with the right arguments every time.

| | English (1325 requests, $1.21) | Thai (485 requests, $1.05) |
|---|---|---|
| Chat, first sentence, warm p50 | 1.50–1.63 s for all five | Sonnet `low` 1.25 s, Sonnet `medium` 1.43 s, Haiku disabled 1.50 s, Sonnet `between_tools` 1.78 s, Haiku `low` 1.87 s |
| Tool turn, first sentence after the tool, warm p50 | 2.74–3.24 s | 1.79–3.00 s |
| The tool call itself (first request), warm p50 / p95 | — | Sonnet `medium` 0.96 / 1.32 s, Sonnet `low` 0.94 / **8.94 s**, Sonnet `between_tools` 2.06 / 2.57 s, Haiku 0.92–1.03 / 1.43–2.01 s |
| Cost per chat turn | Haiku $0.0001, Sonnet $0.0019 | Haiku $0.0002–0.0003, Sonnet $0.0045–0.0050 |
| Text-to-speech start (`speak` to `didStart`) | 2 ms p50 (Samantha) | 2 ms p50 (Kanya) |

- **No configuration met 0.7 s.** About 0.9–1.3 s passes before the first token whatever the model. Haiku was not faster than Sonnet.
- **Thai was faster than English** for Sonnet chat, because of two things:
  - the persona keeps replies short;
  - the Thai splitter can end a sentence at a particle such as นะ.
- **Thai costs about 2.3× English per Sonnet turn**, close to the 2.4× token ratio in `CLAUDE.md`.
  - At 100 turns a day, Sonnet costs about $14–15 a month.
  - That is within the owner's budget of $50 a month and the $100 of plan credits.
- **Sonnet `low` sometimes stalled on a tool call**, for up to about 9 s at p95. The cause was not investigated. Sonnet `between_tools` and `medium` showed no such tail.
- **Follow-up turns sent the history back without a 400.** So the client's re-encoded thinking blocks, with sorted keys, pass the preserved-thinking check.

## The owner's blind rating (Thai run)

The owner rated 30 answers, 6 per configuration, from 1 to 5 for how much they sounded like the Kanade they want.

| Configuration | Mean | Scores |
|---|---|---|
| Sonnet `low` · `between_tools` | **3.50** | 4 1 4 4 4 4 |
| Sonnet `low` | 3.00 | 5 5 2 1 1 4 |
| Sonnet `medium` | 2.83 | 4 4 2 2 1 4 |
| Haiku `low` | 2.50 | 1 1 4 1 4 4 |
| Haiku `low`, thinking disabled | 1.83 | 2 1 1 1 1 5 |

- With 6 answers each, the three Sonnet configurations are close. Haiku is clearly behind.
- The answers scored 1 were the longest, about 800 characters of Uriel's text against 470 for the answers scored 5.
- Only 3 of 30 answers used ค่ะ or คะ. The owner then asked for sweet, polite speech with ค่ะ/คะ and ชั้น, so the persona was changed after this run (commit "Make Uriel speak politely with ค่ะ and คะ"). The run measured the earlier prompt.

## What the decision costs

- Chat with Sonnet `between_tools` reaches the first spoken word about 2.6 s after the owner stops speaking (1.78 s plus the 0.8 s timer). Sonnet `low` would be about 0.5 s faster, but it rated lower and had the tool-call stall.
- With `between_tools`, effort cannot change within a conversation (`CLAUDE.md`, Thinking).
- With tool turns confirmed locally, Claude's text after a tool result is not spoken (ADR 0010).
