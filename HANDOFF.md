# Relay development handoff

Updated 2026-10-20 for version **0.6.2, build 9**. Read [TESTING.md](TESTING.md)
for the evidence and limitations behind this status.

## Intended interaction

Hold Space for 2.5 seconds, keep holding, and speak a sequence of instructions.
Relay should start complete, stable steps while the person continues speaking.
Release stops microphone capture immediately; accepted steps finish in order.
Shift-Command-Escape stops capture, the current run and queued work. Feedback is
silent, through a small nonactivating status capsule near the top of the screen.
There is no wake word, automatic listening on launch or spoken response.

The requested experience includes opening Chrome, navigating to YouTube or X,
and opening ChatGPT/Claude and typing into the intended thread's composer. Literal
dictation must preserve the words spoken. General workflows use a personal Jev /
TypeSafe key; supported direct navigation and typing commands do not require it.
There is no runtime local LLM. These are product goals and implemented paths,
not a claim that every real-app scenario has passed.

## Current state and last stopping point

- The app and its clean source export compiled; 96 automated checks passed.
- Public repository: [lhz56/relay](https://github.com/lhz56/relay), branch `main`.
  The initial public source also passed [hosted macOS CI](https://github.com/lhz56/relay/actions/runs/39532353851),
  including all 96 checks, app build/signature verification and source audit.
- The Keychain freeze is fixed in the tested recovery path: an inaccessible key
  returns an actionable message and the interface remains usable. Direct tasks
  can start without a key. Setup offers **Use for this session**.
- A Chrome launch fix detects when all running Chrome instances are headless and
  requests a separate instance. A non-headless process launched during the trial.
- The current Chrome → YouTube trial did **not** reach verified completion. Focus
  repeatedly changed to iPad Simulator, so verification paused. Both navigation
  actions being issued is not proof that the page opened successfully.
- The trial was stopped with Shift-Command-Escape and microphone capture stayed
  off. Hands-on computer-control work was paused at the user's request. Repository
  publication does not resume that trial.
- No successful human-spoken end-to-end 0.6.2 workflow has been recorded. The
  current Jev HTTP path still needs a successful connection test with an accessible
  key entered inside the app. Do not request or paste a key into chat or source.

## Architecture map

| Area | Main files | Responsibility |
| --- | --- | --- |
| Native UI / orchestration | `Sources/RelayApp/RelayApp.swift`, `AppState.swift`, `AppState+Voice.swift` | Setup, session state, task startup, serialized voice queue and controls. |
| Physical activation | `HotKeys.swift`, `RelayKeyboardEvent.swift`; core `SpaceHoldGate.swift` | Hold timing, short taps, cancellation, distinguishing generated keys from physical input. |
| Audio / feedback | `VoiceInput.swift`, `VoiceOverlay.swift` | Required on-device English speech, segmentation and silent overlay. |
| Streaming speech | `Sources/RelayCore/LiveVoiceGate.swift`, `SpeechIntent.swift`, `TextChunks.swift` | Stable clauses, recognition revisions, literal chunks, exactly-once acceptance and queue barriers. |
| Task engine | `RunEngine.swift`, `Models.swift`, `DirectWorkflow.swift` | Observe → decide → execute → verify; direct commands, approvals, cancellation and bounded retries. |
| General planning | `RestrictedJevPlanner.swift`, `PrivateTask.swift` | Minimized model context, masked payload references, fixed endpoint and response validation. |
| Native computer | `Sources/RelayApp/MacComputer.swift`, `AXScanner.swift`, `AppCatalog.swift` | Accessibility, local observation/OCR, app targeting, keyboard actions and local verification. |
| Chrome launching | `ChromeLaunch.swift`; core `ChromeLaunchPolicy.swift` | Read argv locally, detect actual headless flags, preserve existing automation processes. |
| Credentials | `KeyStore.swift` | Serialized noninteractive Keychain calls off the main actor. Task startup uses only the cached session key. |

`JevPlanner.swift`, `ModelClient.swift` and `LocalModelClient.swift` contain older
paths and fixtures. Their presence does not mean the current app offers provider
switching or uses a local LLM; `AppState` constructs `RestrictedJevPlanner`.

## Changes included in this source snapshot

The voice work added live stable-clause acceptance, ordered multi-instruction
execution, literal dictation mode, recognition-revision handling, immediate
capture stop on release, and a silent overlay. The fixed starting-app picker was
removed in favor of the intended app. Copy checks only the pasteboard change
counter. Claude routing and X's `/home` landing path have fixture coverage.

Version 0.6.2 fixes the startup freeze caused by synchronous Keychain reads while
another read waited for authentication. `KeyStore` is an actor, startup reads
asynchronously, and task startup never accesses Keychain. Session key entry
works without a successful save. The legacy Keychain interaction flag is restored
after each call; no credential ACLs are changed. Those compatibility APIs produce
deprecation warnings and deserve a deliberate future migration.

Version 0.6.2 also handles preexisting headless Chrome processes. The parser reads
only argv from the bounded process-argument buffer; environment, URLs and profile
paths containing the word `headless` do not count as flags. Raw argument bytes
are discarded and never sent to Jev. Unknown or mixed visible/headless instances
do not trigger a forced new instance.

## Boundaries to preserve

- Mic capture must remain explicitly user initiated. Release and Stop are separate:
  release permits accepted work to finish; Stop cancels pending work.
- One executor owns the queue. Approval, clarification, pause and error stop later
  queued instructions from overtaking the current one.
- Revised recognition must not replay accepted actions. Literal dictation must not
  reinterpret ordinary command-like phrases as navigation.
- Jev receives minimized, masked task data and local findings, not raw screen text,
  dictated payloads, screenshots, clipboard contents or previous task histories.
  Masking is best effort, not a proof that arbitrary instructions contain no private data.
- Secure credential steps stay with the user. Unrelated foreground apps interrupt
  the workflow. Consequential actions pass the existing approval checks.
- Model actions cannot execute arbitrary shell commands. Direct tasks bypass Jev.
- No API keys, runtime preferences, recordings, private diagnostics or app binaries
  belong in the repository. Task history is currently in memory only.

## Next hands-on work, when requested

1. Arrange an uninterrupted foreground session. Open the exact installed build and
   confirm Accessibility plus **Space shortcut ready**. Ad-hoc rebuilds can require
   removing and adding the app's permission entry; never bypass macOS authentication.
2. Run a harmless typed Chrome → YouTube task and verify the visible URL and final
   completed status. Leave unrelated headless browser processes running.
3. Have the user hold Space, wait for Listening, then speak that workflow and a
   second instruction while the first runs. Verify execution begins while held,
   release turns capture off, accepted steps finish once, and Stop clears the queue.
4. Dictate synthetic text into an intentionally focused ChatGPT/Claude composer;
   verify exact text, leading spaces between chunks and no automatic Send.
5. Enter the personal key in Setup → Use for this session and test Jev with the
   synthetic connection check. Then try one harmless general planning task.
6. Measure actual activation-to-listening and speech-to-first-action latency.
   Normalization microbenchmarks are not end-to-end latency measurements.

Live tests still needed include recognition accuracy, physical-key behavior,
five-minute capture limits, and recognition rotation at 50-second boundaries.
Rotation has a 400 ms finalization interval; lossless continuous transcription
has not been established. Intel, macOS 14, distribution signing, notarization and
permission continuity across upgrades are also unverified or unimplemented.

## Reproduce / publication status

Run `./scripts/check.sh`, `./build.command` and
`python3 scripts/package-source.py --check` from the repository root. See
[README.md](README.md) for setup and [TESTING.md](TESTING.md) for the test ledger.
Source packaging uses an explicit allowlist. Add intentionally shared documents
there; do not copy the surrounding development workspace into the repository.

This is a developer source preview. `LICENSE.proposed` is a proposal, not an
active license; the owner has not chosen the final license or copyright notice.
There is no notarized binary or claim of a fully validated unattended agent.
