# Validation record

Version **0.6.2, build 9**. Updated 2026-10-20. This record separates automated
fixtures, local builds and native observations from workflows that remain unverified.

## Automated checks: passed

The current implementation passed all **96 debug check cases** locally on
2026-10-19, including a fresh extraction of the source archive without reused
build caches. The runner uses assertions/preconditions, fake computer actions,
synthetic transcripts and fake API transports. It does not capture microphone
audio, send real API calls or interact with real user accounts.

| Group | Cases | Coverage |
| --- | ---: | --- |
| Workflow | 12 | Action validation, completion evidence, approvals, reobservation, stale decisions, cancellation and bounded repetition/errors/steps. |
| Legacy Jev | 8 | Older planner/transport fixtures retained for regression coverage. |
| Voice / navigation | 13 | Speech intent normalization, supported app/site navigation and ordered instructions. |
| Space hold | 8 | Activation threshold, release and cancellation state transitions. |
| Privacy | 7 | Masking and transport boundaries using synthetic private data. |
| Restricted Jev | 11 | Restricted requests/responses, local payload references and invalid/redirect behavior. |
| Direct workflow | 6 | Deterministic workflow sequencing and local verification. |
| Live voice | 20 | Partial hypotheses, stable clauses, revisions, exactly-once acceptance and queue barriers. These are transcript fixtures, not microphone tests. |
| Product | 6 | X navigation, clipboard change-counter verification, Claude routing and literal dictation/spacing. |
| Chrome launch | 5 | Headless argv flags, false positives in URLs/paths/environment, empty arguments, malformed buffers and mixed/unknown process sets. |
| **Total** | **96** | |

Reproduce from the repository root:

```sh
./scripts/check.sh
```

Use the debug check executable, not `swift test`. The successful runner ends with:

```text
PASS: 12 workflow + 8 legacy Jev + 13 voice/navigation + 8 Space-hold + 7 privacy + 11 restricted Jev + 6 direct-workflow + 20 live-voice + 6 product + 5 Chrome launch checks (96 total)
```

## Build / source verification: passed locally

- macOS 26.3, Apple Silicon, Swift 6.3.1: release compilation passed.
- The ad-hoc-signed app passed `codesign --verify --strict`.
- A fresh source archive was extracted and both checks and release build passed;
  the extracted app also passed strict signature verification.
- On 2026-10-20, all **40 implementation/check/build inputs** were compared with
  that clean extraction and still matched byte for byte. The installed executable
  also matched the verified candidate. Both installed and clean-build signatures
  were checked again successfully. This publication work changes documentation
  and source packaging, not the previously validated application implementation.
- The original source export audited 49 allowlisted text files. The handoff and
  this test record add two files to the allowlist. Packaging excludes binaries,
  runtime state, recordings and private diagnostics, rejects symlinks and scans
  common credential/personal-path patterns. This is a heuristic, not a complete
  secret-detection guarantee.
- Expected build warnings: deprecated compatibility APIs used to suppress legacy
  Keychain authentication UI. No distribution signing or notarization was tested.

Implementation fingerprint for the 40 matched inputs:

```text
d92dc7f46168ddab3df03a9793517c19e782582a061b7e47a976b714786ce51f
```

The digest is SHA-256 over sorted relative filenames, each followed by a NUL,
file bytes and a NUL. Inputs are all `Sources/**/*.swift`, `Tests/**/*.swift`,
`Package.swift`, `Info.plist`, `entitlements.plist`, `build.command` and
`scripts/check.sh`. Documentation and the packaging script are intentionally
outside this implementation fingerprint.

Reproduce the release build and source audit:

```sh
./build.command
codesign --verify --strict dist/Relay.app
python3 scripts/package-source.py --check
python3 scripts/package-source.py
```

The generated archive has a SHA-256 sidecar. The GitHub Actions workflow is
configured to run checks, build/signature verification and the source audit.
The first public commit, [ddc4fc4](https://github.com/lhz56/relay/commit/ddc4fc499803af2ed50b848d581c9a17cee91c39),
also passed [GitHub's macOS workflow](https://github.com/lhz56/relay/actions/runs/39532353851):
all 96 checks, release build, strict signature verification and the 51-file source
audit. This independently validates the published source on a hosted runner.
For subsequent commits, inspect their own Actions results.

## Native observations

| Trial | Result and limit |
| --- | --- |
| 0.6.1 Keychain hang | Reproduced and diagnosed: task startup read Keychain synchronously while another read waited for authentication. This motivated the 0.6.2 change. Private process samples are excluded from source. |
| 0.6.2 inaccessible saved key | Connection-test action returned an actionable unavailable-key message without a password dialog; interface stayed responsive. A direct task started without unlocking Jev. This is not a successful HTTP connection test. |
| macOS permissions | Accessibility and Screen Recording refreshed; Setup showed both enabled and Space shortcut ready before the Chrome update. Final binary entries refreshed again and navigation passed the app's permission checks. No final-binary microphone capture trial was performed. |
| Chrome headless detection | Existing headless browser was preserved; a separate non-headless Chrome process started. Process launch alone does not prove a visible window or successful page navigation. |
| Chrome → YouTube | Navigation actions issued, but verification was interrupted by focus switching to iPad Simulator. Task paused. **No completed 0.6.2 native navigation pass claimed.** |
| Global Stop | Shift-Command-Escape stopped the interrupted trial and cleared the pending question. Microphone remained off throughout this recovery trial. |

Historical 0.6 typed navigation and synthetic Jev connectivity had worked, but
those results do not establish that the rebuilt 0.6.2 app or spoken workflow passes.

## Outstanding validation

- Human-spoken hold → listen and act while held → release → complete, including
  adding another instruction during execution and stopping queued work.
- Physical Space interception and short taps in ordinary third-party apps;
  generated typing must not cancel the user's hold.
- Final-binary Microphone/Speech permissions, actual ASR accuracy and measured
  end-to-end latency. No speed guarantee can be inferred from parser benchmarks.
- Literal transcription into real ChatGPT/Claude composers, including correct
  target/thread, chunk spacing and absence of unintended submission.
- Successful Jev HTTP connection and a harmless general planning workflow using
  a key entered only inside Relay.
- Longer dictation, 50-second segment rotation, possible audio gaps and five-minute
  capture cutoff; lossless continuous dictation is not claimed.
- Intel, the declared macOS 14 minimum, distribution signing/notarization and
  upgrade permission continuity.

See [HANDOFF.md](HANDOFF.md) for the current stopping point and suggested next
trials. Automated checks are useful regression evidence; they do not prove that
the entire computer-control experience is ready for unattended daily use.
