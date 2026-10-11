# ADR 0001 — A native Swift menu-bar app

- **Status:** accepted
- **Date:** 2026-10-11
- **Decided by:** the owner

## Context

Raphael is a personal voice assistant for one MacBook Air M4 (macOS 26). It
listens for its name, talks back, chats through the Claude API and acts on the
Mac (opening apps, timers). Almost every capability it needs is a Swift-first
Apple API: `SpeechAnalyzer`, `AVSpeechSynthesizer`, `NSWorkspace`,
`UserNotifications`, and later EventKit, App Intents, ScreenCaptureKit and
Foundation Models.

macOS grants privacy permissions (TCC: Microphone, Automation, Accessibility,
…) to the responsible process. A script gets its grants through Terminal or
through its interpreter (`python3`, `bun`), which then holds them for every
script it runs. One signed app bundle with a stable bundle ID is the only clean
way to hold the grants.

## Decision

Write Raphael as a native Swift app that lives in the menu bar (SwiftUI
`MenuBarExtra`, `LSUIElement` so there is no Dock icon). One app bundle holds
every permission and does all the work: ears, mouth, hands, and the Claude
client.

## Trade-off

- **Gain:** direct access to every Apple API above; one TCC identity; the most
  power-efficient path on a fanless Air (Core ML / Neural Engine); one process
  to run.
- **Cost:** Anthropic has no official Swift SDK, so we write the Claude client
  and the tool loop ourselves (ADR 0002). Swift 6 strict concurrency is strict
  about audio callbacks and actors.

## Alternatives

- **Swift shell + Python or Bun brain:** the official Claude SDK, but two
  languages, an IPC protocol and a bundled runtime. Not chosen.
- **Python only:** fastest prototype, but TCC grants land on `python3`,
  EventKit and notifications need a bundle anyway, and packaging an
  always-on app is awkward. Not chosen.
- **TypeScript/Bun:** weakest reach into native APIs; everything goes through
  `osascript`, `shortcuts` or helper binaries. Not chosen.
