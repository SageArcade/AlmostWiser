# AlmostWiser

## 2026-11-13 — Voice capture

- **Decision** — Voice is the task-entry workflow. Start with live Apple Speech recognition at the existing iOS 18.6 minimum. Use on-device recognition when supported for the recognizer's locale, with Apple recognition service available otherwise.
- **Progress** — Tap Start listening, speak, and tap Stop listening. The screen displays partial results and keeps the final text for the current session.
- **Known limits** — This milestone covers transcription. Recognition quality and latency need testing on the iPhone 13 mini, especially for names, mixed languages, and background noise.
- **Next** — Run on the 13 mini, allow microphone and speech access, and verify live text, final text, and a second recording. Compare accuracy and latency with real voice notes before choosing whether to add another recognizer. Then extract tasks from the transcript.

## 2026-11-17 — Action button

The current minimum is iOS 26.6. AlmostWiser publishes a built-in **Start Listening** App Shortcut. On supported iPhones, choose it under Settings → Action Button → Shortcut. It queues capture before requesting the foreground. Opening the app icon shows the idle screen. The URL `almostwiser://listen` remains available for comparison through Shortcuts.

On the test iPhone, median scene activation to microphone start dropped from 1,070 ms to 375 ms with the built-in shortcut. The new URL runs measured 367 ms. These logs do not measure physical button-press latency.

To repeat the test, install a Debug build and filter the connected iPhone's logs in macOS Console for `AWTiming`. Compare several runs from the Home Screen with the app terminated and with it in the background. Use an external video to measure physical press to visible microphone indicator. The timing logs contain no transcript text.

Next, verify the cleaned-up build on the phone, then extract tasks from the transcript.
