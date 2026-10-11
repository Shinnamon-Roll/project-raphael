# ADR 0007 — A stable local signing identity, hardened runtime, no App Sandbox

- **Status:** proposed (the owner has not confirmed it yet; the identity is the owner's choice)
- **Date:** 2026-10-11
- **Proposed by:** research, v1 planning

## Context

This Mac has no code-signing identity (`security find-identity -v -p
codesigning` finds 0). macOS remembers privacy grants such as the microphone
against the app's designated requirement. With ad-hoc signing ("Sign to Run
Locally") that requirement is tied to one build (TN3127), so permission and
Keychain prompts come back after rebuilds. Under the hardened runtime the
microphone needs the `com.apple.security.device.audio-input` entitlement. The
App Sandbox is required only for the Mac App Store.

## Decision

- Sign every build with one stable identity: an Apple Development certificate
  from a free Apple ID Personal Team, or a self-signed code-signing certificate.
  The owner chooses, and also picks the bundle ID once.
- Hardened runtime on, with only `com.apple.security.device.audio-input`.
- No App Sandbox in v1.

## Trade-off

- **Gain:** permissions and Keychain access survive rebuilds; the path to
  Developer ID and notarization stays open.
- **Cost:** a one-time setup by the owner. Without the sandbox, a compromised
  process has the owner's file access; ADR 0005 is the guard against the model.

## Alternatives

- **Ad-hoc signing:** no setup, but prompts return after rebuilds. Not chosen.
- **A paid Developer ID:** not needed for a personal v1. Not chosen.
- **App Sandbox:** more entitlements to manage, and it blocks Later items
  (Apple Events, Shortcuts). Not chosen.
