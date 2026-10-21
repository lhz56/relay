# Relay

A silent, voice-controlled macOS computer agent. Hold Space, speak instructions,
and keep talking while Relay executes complete steps in order. A compact animated
status capsule appears near the top of the screen without taking app focus.
Release Space to stop capture; already accepted steps finish.

**Version 0.6.2 · developer preview.** This is a reviewable source preview.
The final license and copyright notice remain undecided; `LICENSE.proposed` is
not an active license. There is no bundled key or notarized binary in this package.
A successful end-to-end human-spoken hold-to-act trial is still outstanding;
automated speech fixtures are not proof of microphone accuracy.

## Requirements

- macOS 14 or newer. Local validation: macOS 26.3, Apple Silicon, Swift 6.3.1.
  Intel and the oldest supported OS have not been tested.
- Swift 5.9+ from Xcode or Apple's Command Line Tools, plus the macOS SDK.
- On-device English (en-US) speech recognition and a working microphone.
- Accessibility permission for computer control and the global Space gesture.
- Microphone and Speech Recognition permission, requested on first voice use.
- Screen Recording only if you enable optional local OCR.
- A personal Jev/TypeSafe API key for general planning. Exact supported direct
  commands work without a key and make no Jev calls.
- Python 3.9+ only for source packaging. It is not a runtime dependency.

There are no external Swift package dependencies. Relay uses Apple frameworks
and a fixed HTTPS Jev endpoint. It uses no local LLM or cloud writing model.

## Build and check

From this source folder:

```sh
./scripts/check.sh
./build.command
open dist/Relay.app
```

`check.sh` runs 96 assertion-based checks in **debug** mode. Use this command,
not `swift test`; the project ships a standalone check executable. Tests use
synthetic fixtures, fake computer actions and fake transports. They require no
API key, microphone capture or account access. The local app build is signed
ad hoc and verified with `codesign --verify --strict`.

Optional build overrides: `RELAY_BUILD_DIR` selects a Swift build directory;
`RELAY_APP_DIR` selects the resulting `.app` path; `RELAY_SIGN_IDENTITY` selects
a signing identity you already own (default `-`, ad hoc). Never put signing
credentials or API keys in source. This builds for the current architecture;
it does not produce a notarized or universal release. Keep the installed app
in a stable location. Quit a running copy before replacing its bundle.

## Set up on your Mac

1. For general planning, open Relay → Setup and enter your personal Jev key in
   the secure field. Use for this session keeps it in memory until Relay quits.
   Save key also attempts to store it in macOS Keychain; if macOS refuses, it
   remains available for this session. Test Jev connection uses synthetic data
   and does not inspect the real screen. Supported direct commands need no key.
2. Allow the actual built Relay.app in System Settings → Privacy & Security →
   Accessibility. Return to Setup and choose Refresh permissions. It should say
   **Accessibility Enabled** and **Space shortcut ready**.
3. If using local OCR, enable Screen & System Audio Recording for that same app.
4. Start voice input when you are ready to grant Microphone and Speech Recognition
   access. Do not test capture during another voice conversation: Relay can hear
   nearby speech. There is no microphone capture on launch.

Rebuilding an ad-hoc-signed app changes its signing identity. A permission switch
can look enabled while macOS rejects the replacement. Quit Relay, remove the old
entry from the relevant privacy list, add the new app, then reopen it. macOS may
require your password. Do not disable system security protections to work around
this. A public binary release needs a deliberate signing/notarization strategy.

## First hands-on trial

1. Switch to an ordinary app. Hold **Space for 2.5 seconds** and keep it held.
2. Wait for the capsule to say **Listening**, then say **“Open Chrome, then open
   YouTube.”** Keep holding as the first action begins; you can add more steps.
3. Release Space. The microphone turns off and accepted work finishes.
4. **Shift-Command-Escape stops capture, the current task and queued work.**
   It does not undo completed actions.

No wake phrase is needed. A short Space tap still types a normal space. Other
physical keys/modifiers cancel the hold; Relay's own generated keystrokes do not.
If interception is unavailable, use **Shift-Command-V** to toggle listening instead.
**Shift-Command-H** is an alias; **Shift-Command-Space** opens Relay. A session
has a five-minute upper bound. Relay never speaks back.

A stable, explicit navigation clause can start before the following clause is
finished. Other instructions wait for a short speech pause (default 0.8 seconds;
existing user preferences are retained). That is not total action latency: app
launching, recognition, observation and Jev can take longer. Typing, clicks and
network operations remain serialized so later instructions cannot overtake them.

## Supported examples

| Say | Behavior and conditions |
| --- | --- |
| “Open YouTube” | Opens the site in the active supported browser or default browser. |
| “Open Chrome, then open Twitter” | Opens Chrome, then x.com; handles its /home landing page. Login remains yours. |
| “Copy the current selection” | Sends Copy in the intended app and checks the clipboard change counter; clipboard contents are not read or uploaded. |
| “Open ChatGPT app and write on this thread that hello” | Opens ChatGPT and types literal words into an unambiguous composer; does not send. |
| “Type hello from Relay” | Types into the current intended editable field. Put the cursor there first. |
| “Start transcribing into Claude” | Opens Claude and enters dictation mode. Pause after the mode command, then speak your exact text. |
| “Start dictating” | Uses the current app and field. Subsequent chunks are literal text, including command-like words and fillers. |
| “Stop dictation” | Returns to instruction mode while capture remains active. Releasing Space also exits dictation. |

If the only running Chrome instances are headless automation processes, Relay
opens a separate visible instance. It does not stop those background processes
or change their profiles. It checks Chrome launch arguments locally solely for
the headless flag; those arguments are never included in history or AI context.

While dictating, keep each sentence together; a pause can commit a chunk.
“Stop,” “pause,” “resume,” “approve” and “stop listening” remain reserved controls,
so avoid using them as standalone dictated utterances. Other workflows use Jev
with limited context and can ask for clarification. “This video” or a private
thread is not guaranteed to resolve without selecting it yourself. Browser
search/play, creating notes, and arbitrary workflows are not advertised as
fully verified merely because their constituent actions exist.

An approval, question, pause or error blocks later queued instructions. A spoken
answer to a pending question stays with that task. Navigation aliases and transient
recognition corrections do not repeat accepted actions. A stable material change
to already accepted speech pauses further work; it cannot undo previous actions.

## Privacy and limits

Speech runs in Apple's required on-device mode. Dictated words stay local until
you deliberately type them into the destination app. Jev receives only minimized
instructions with recognized private payloads replaced by opaque references,
common control names, action kinds and local verification findings. Full screen
text, field contents, clipboard content, window titles, screenshots, full OCR,
and previous-task histories are excluded. Task history remains in memory until
quit; this version does not write new history files.

Masking cannot detect every private detail in arbitrary instructions. Destination
apps retain their own network behavior; typing into a website is not offline.
Provider retention and usage charges depend on your service terms. See
[SECURITY.md](SECURITY.md), [TypeSafe's API reference](https://api.typesafe.ai/redoc)
and its [privacy policy](https://typesafe.ai/legal/privacy-policy).

Relay observes the selected app and apps explicitly opened by the task. An unrelated
foreground app interrupts the workflow. Secure fields, credential steps and
sensitive system apps require a handoff. Send/Submit, Delete, purchase and other
consequential actions can require review. Arbitrary shell execution is unsupported.
There are bounds on repeated actions, errors and decisions per run. This remains
a preview, not a security sandbox or a promise to operate every application.

## Troubleshooting

- **Space does nothing:** Relay must be running. Check Accessibility and Space
  shortcut ready. Secure keyboard entry or another keyboard utility can interfere;
  try Shift-Command-V. Wait for Listening before speaking, and keep Space held.
- **Setup looks enabled after a rebuild but control fails:** refresh the actual
  app entries as described above. Reopen the correct copy, not an old duplicate.
- **No audio/on-device recognizer unavailable:** check the macOS input device and
  Microphone/Speech Recognition permissions. Only on-device en-US recognition is
  configured. Text tasks remain available; there is no silent cloud-ASR fallback.
- **Jev key unavailable:** a rebuild can lose access to the saved Keychain item.
  Relay's background key lookup returns without requesting authentication or
  blocking the interface. Enter the key in Setup and choose Use for this session.
  Direct commands remain usable. Do not paste keys into issues or chats.
- **Jev HTTP error:** use Test Jev connection and inspect the provider response.
- **Wrong target or no editable field:** stop, select the intended app/composer,
  then activate again. “Open an app” does not always focus its text box.
- **Recognition revision pause:** check what already happened, then resume or start
  a corrected task. Relay deliberately avoids replaying a changed partial transcript.
- **A step cannot be verified:** inspect the app and answer Relay's question. A
  proposed or issued action is not automatically considered successful.
- **Long dictation:** recognition rotates into new segments. Segment boundaries,
  timing and microphone accuracy still require broader live testing. Do not rely
  on this preview for lossless unattended transcription.

## Release and development

Start with [HANDOFF.md](HANDOFF.md) for the architecture, latest fixes and next
steps, and [TESTING.md](TESTING.md) for passed checks and outstanding live trials.
See also [CONTRIBUTING.md](CONTRIBUTING.md),
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and
[RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md). The CI definition runs checks,
builds the app and audits release inputs. Check the Actions result for the commit
being reviewed; local validation alone does not establish a hosted CI pass.

```sh
python3 scripts/package-source.py --check
python3 scripts/package-source.py
```

The package script includes only allowlisted source/docs, normalizes archive
metadata and emits a SHA-256 file. It excludes builds, application state, recordings,
Keychain contents and personal paths. Its pattern scan is not a universal secret
detector. Inspect the archive before sharing. A clean extracted-source build and
the remaining live-verification limits are recorded in the release checklist.

MIT is proposed in LICENSE.proposed; no ownership identity has been invented.
The owner must choose the final license and copyright notice before this can be
described as a licensed open-source release.
