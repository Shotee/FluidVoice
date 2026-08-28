# FluidVoice Live handover

## Goal

Build an Aqua Voice-style inline streaming dictation prototype as a separate
`FluidVoice Live` development app. Short Japanese dictations should appear in
the focused field while recording and be replaced once with the final result.

## Current state

- Fork: `Shotee/FluidVoice`; upstream: `altic-dev/FluidVoice`.
- Tracking issue: `Shotee/FluidVoice#1`.
- Working branch: `codex/inline-streaming-dictation`.
- Official FluidVoice 1.6.9 and the Japanese Cohere model are installed.
- GitHub CLI authentication for `Shotee` was renewed.
- An Apple Development signing identity is not installed yet.
- The isolated unsigned Live app builds at
  `/private/tmp/fluidvoice-live-build2/Build/Products/Debug/FluidVoice Live.app`.
- The Live app launches and reuses the installed Cohere artifacts without a
  second download. Microphone access is granted; Accessibility access is still
  awaiting explicit approval.
- All 355 project tests pass after the final safety-hardening patch.

## Decisions

- Inline typing is enabled by default for normal dictation only.
- Command, Rewrite, Prompt, Spoken Send, secure fields, and terminals retain the
  existing final insertion behavior.
- Cohere inline updates freeze before its 12-second rolling preview window; the
  full final transcription replaces the provisional range on release.
- Focus, caret, or external text changes interrupt inline mutation. The final
  text is copied instead of risking destructive insertion.
- Fluid Intelligence interoperability is an optional spike and does not block
  the MVP.

## Next steps

1. Grant Accessibility access to the unsigned Live build and perform the first
   short-dictation test in an allow-listed app.
2. Configure a Personal Team signature so Accessibility permission survives
   rebuilds.
3. Commit and push the implementation branch; update issue #1 with results.
