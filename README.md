# AlmostWiser

## 2026-11-13 — Voice capture

- **Decision** — Voice is the task-entry workflow. Start with live Apple Speech recognition at the existing iOS 18.6 minimum. Use on-device recognition when supported for the recognizer's locale, with Apple recognition service available otherwise.
- **Progress** — Tap Start listening, speak, and tap Stop listening. The screen displays partial results and keeps the final text for the current session.
- **Known limits** — This milestone covers transcription. Recognition quality and latency need testing on the iPhone 13 mini, especially for names, mixed languages, and background noise.
- **Next** — Run on the 13 mini, allow microphone and speech access, and verify live text, final text, and a second recording. Compare accuracy and latency with real voice notes before choosing whether to add another recognizer. Then extract tasks from the transcript.
