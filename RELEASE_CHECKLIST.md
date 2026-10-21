# Release candidate 0.6.2

Prepared 2026-10-19; updated 2026-10-20 for the requested GitHub source preview.
See [HANDOFF.md](HANDOFF.md) for context and [TESTING.md](TESTING.md) for the test
ledger. Public source availability does not finalize the proposed license or
establish readiness for a binary release.

Published at [lhz56/relay](https://github.com/lhz56/relay). The initial public source
passed [hosted macOS CI](https://github.com/lhz56/relay/actions/runs/39532353851),
including all 96 checks, app build/signature verification and the 51-file audit.

## Verified locally

- 96 debug checks passed: workflow sequencing, approvals, cancellation, limits,
  privacy transports, navigation, Space timing, streaming hypotheses, revisions,
  queued work, copy verification, Claude routing, literal dictation chunks and
  distinguishing headless Chrome processes from visible browser instances.
- Release app compiled on macOS 26.3 / Apple Silicon / Swift 6.3.1.
- Local ad-hoc code signature passed strict verification.
- Runtime capture remains user-initiated. No microphone test was started while
  recovering the app or preparing this candidate.
- No external SwiftPM dependencies, bundled model, shared API key or vendored assets.
- Source export is allowlisted; build/runtime data are not release inputs.

## Final validation record

The 0.6.1 hang was reproduced and diagnosed with a process sample: task startup
was synchronously reading Keychain on the main thread while the background
connection test waited for authentication. That process was stopped. Version
0.6.2 serializes noninteractive Keychain calls on a background actor, caches keys
in memory, and never reads Keychain during task startup. Local direct commands
no longer depend on the presence or availability of a Jev key. Session-only key
entry is available without a Keychain write. Existing credential ACLs are unchanged.

Native recovery verification: with the saved key unavailable, Test Jev connection
returned an actionable message without a password dialog, and the Task screen
remained responsive. A direct Chrome → YouTube task started without unlocking
Jev. Accessibility and Screen Recording were refreshed for the installed app;
the setup UI confirmed those permissions and the Space shortcut ready before
the final Chrome-specific update. The final binary's permission entries were
refreshed again before its native navigation trial, which passed the app's
permission checks and started successfully. Shift-Command-Escape stopped the
interrupted trial and cleared its pending question; microphone capture stayed off.

The first navigation trial found only a headless Chrome automation process.
The update launched a separate non-headless Chrome process and left the existing
headless process running. The subsequent trial issued both navigation actions
but could not verify YouTube because focus moved to iPad Simulator. The app
paused for input; the full native navigation result remains unverified. No
successful human-spoken 0.6.2 workflow is claimed. The Jev HTTP connection also
remains untested until the user supplies an accessible key in the app.

Current-source debug checks and release compilation/signature verification passed.
A fresh source archive was extracted without copying build caches: all 96 checks
passed and the release app compiled and passed strict signature verification.
All 40 implementation/check/build inputs matched the installed release source.
The installed executable matches the verified candidate. Only validation notes
were updated after the extracted-source check. The build reports deprecation
warnings for the compatibility APIs used to suppress legacy Keychain UI.

The original source audit passed for 49 allowlisted text files, excluding binaries,
recordings and runtime state. Packaging rejects symlinks and common credential
and personal-path patterns and normalizes ordering, timestamps and ownership.
A separate SHA-256 accompanies the archive; the heuristic scan is not a guarantee
against arbitrary secrets. The handoff and test ledger bring the current source
allowlist to 51 files. The 40 implementation/check/build inputs still match the
clean validated extraction; publication changes only docs and packaging.

## Outstanding owner decisions and release work

- Confirm rights/ownership, choose a license and copyright notice. MIT is proposed;
  LICENSE.proposed is not an active license. Do not claim this is already open source.
- Configure a real private security-reporting channel and update SECURITY.md.
- Complete the human-spoken hold → listen/act → release trial, including a second
  instruction while the first runs, transcription into an intended field, and Stop.
- Verify microphone permissions and accuracy on the intended hardware. Core tests
  cannot validate actual audio recognition, physical keys or third-party UI behavior.
- Review the package and known limitations. Confirm the supported OS/architecture
  matrix before widening claims beyond the locally tested Apple Silicon system.
- For a downloadable app: decide ownership of a signing identity, notarization,
  distribution and upgrade/permission migration. This source package supplies no
  signing credentials and does not implement an automatic updater.
- Keep checking hosted CI for subsequent changes. The initial publication passed;
  each later commit has its own result, separate from local validation.

The source preview discloses the pending license decision and remaining live
validation. Do not market it as a licensed open-source release or a fully
validated general-purpose or unattended computer agent.
