# ADR 0003 — On-device voice: wake word, Apple speech-to-text, a female English voice

- **Status:** accepted (wake-word engine still open)
- **Date:** 2026-10-11
- **Decided by:** the owner
- **2026-10-11:** the wake word was renamed from "Raphael" to "Uriel" by the owner.

## Context

The owner says "Uriel" and speaks English; Uriel answers by voice in
English, in a female voice. The owner wants the wake word in v1, not
push-to-talk, and free, local speech. macOS has no public API for a custom
wake word: Siri listens only for "Siri" and "Hey Siri". Picovoice Porcupine no
longer offers a personal or free plan (a one-time 7-day trial, then enterprise
sales only).

## Decision

- **Wake word:** an on-device keyword spotter for "Uriel", running in the
  app. The engine is picked by a measured spike on this Mac (false triggers per
  hour, misses, CPU), between sherpa-onnx keyword spotting (Apache-2.0, Swift
  bindings, no training) and continuous `SpeechAnalyzer` transcription with a
  keyword match. Porcupine is ruled out by its licence.
- **Speech-to-text:** Apple `SpeechAnalyzer` / `SpeechTranscriber` with
  `SpeechDetector` (macOS 26, on device).
- **Text-to-speech:** `AVSpeechSynthesizer` with a female English voice, ideally
  a downloaded Premium voice. The owner picks the voice by ear.
- Only text goes to the Claude API. Audio stays on the Mac.

## Trade-off

- **Gain:** free, offline speech; Apple maintains and updates the models; the
  Neural Engine keeps power and heat low on a fanless Air; no audio leaves the
  Mac.
- **Cost:** an always-on mic (the orange indicator stays on) and a wake word
  whose accuracy must be measured before we rely on it. `SpeechAnalyzer` has no
  custom vocabulary. Apple voices sound less natural than the best neural TTS.

## Alternatives

- **Push-to-talk for v1:** simpler and no always-on mic. The owner chose the
  wake word.
- **openWakeWord:** trains a custom word well, but runs only in Python and its
  pretrained models are CC BY-NC-SA. Not chosen for a Swift app.
- **WhisperKit or Parakeet for speech-to-text:** comparable or better accuracy,
  but a model to ship and update ourselves. Kept as a fallback.
- **Kokoro or ElevenLabs for the voice:** more natural; Kokoro is local but a
  model to ship, ElevenLabs is paid and online. Kept for later.
