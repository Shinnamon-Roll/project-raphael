# ADR 0004 — Uriel keeps its own timers

- **Status:** accepted
- **Date:** 2026-10-11
- **Decided by:** the owner

## Context

"Set a timer for ten minutes" is a v1 command. The macOS Clock app has no
public API: no AppleScript dictionary, and AlarmKit is not available to native
macOS apps. Its timer actions are reachable only through a shortcut the user
builds in Shortcuts.

## Decision

Uriel runs the countdown itself. When a timer ends, it posts a notification
through `UNUserNotificationCenter` and says so out loud.

## Trade-off

- **Gain:** works with no setup by the owner; Uriel knows every timer it set,
  so it can answer "how long is left?" and cancel timers by voice.
- **Cost:** timers are not shown in the Clock app, and they end when Uriel
  quits unless we persist and restore them.

## Alternatives

- **Clock timers through a user-built shortcut (`shortcuts run`):** visible in
  Clock and survive Uriel quitting, but the owner must build and maintain the
  shortcut, and Uriel cannot list or cancel them reliably. Not chosen.
- **Reminders through EventKit:** survive restarts and sync to the iPhone, but
  a reminder is not a timer. Kept for later.
