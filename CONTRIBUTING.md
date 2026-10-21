# Contributing

This is a reviewable release candidate. The owner must finalize LICENSE and a
private security-reporting channel before soliciting public contributions.

Use macOS 14 or newer and Swift 5.9 or newer from Xcode or Command Line Tools.
Run `./scripts/check.sh` for the assertion-based debug checks and `./build.command`
for a signed local app in `dist/Relay.app`. The checks use synthetic fixtures and
fake transports: do not add a real API key or require live microphone capture
in automated tests. `swift test` is not the project's check entry point.

Keep capture and execution separate. Preserve focus, ordered actions, release
and stop behavior, and handling of revised recognition results. Add regression
checks for changes to these boundaries. Never solve a missing-context problem
by sending raw screens, dictated text, clipboard contents or task history to a
provider. Keep new UI feedback silent and distinguish verification from merely
issuing a click or keystroke.

Check `SECURITY.md` before reporting a bug. Include reproducible steps with
synthetic text, macOS/Swift versions, expected behavior and actual behavior.
No private data or credentials are needed for a useful report.

Build products, local environment files, recordings, crash logs and credentials
are excluded by .gitignore and the source package allowlist. Inspect every
release archive and run its clean build; the source audit is not a universal
secret detector.
