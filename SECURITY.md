# Security and privacy

Relay controls the foreground app using macOS Accessibility permissions. Treat
it as a development preview. It is not an OS sandbox or a guarantee against
prompt injection, speech mistakes or incorrect model decisions.

## Credentials

Enter a personal Jev key only into Relay → Setup → Jev API key. Use for this
session keeps it in memory until quit. Save key also attempts storage in macOS
Keychain under service `local.relay.agent`, account `Jev · TypeSafe`; if saving
is denied, Relay reports that the key is available for this session only.
There is no bundled key, environment-file loader, shared backend or alternate
provider fallback. The connection check uses synthetic data. The key is not
printed in logs or included in source releases. Rotate a compromised key at
the provider, then replace it in Relay's secure field. Quit Relay to clear its
in-memory key cache. Use Keychain Access to remove the stored entry if desired.

Keychain operations are serialized on a background actor. The existing
file-based Keychain implementation uses the deprecated macOS interaction flag
to suppress authentication UI during these calls; the previous flag is restored
after each call. Denial fails closed. Relay does not change item ACLs, unlock
Keychain, migrate/delete credentials or grant itself access. Task execution uses
only the in-memory key, so a pending Keychain operation cannot block task startup.

To avoid sending interactive browser requests to headless automation, Relay checks
the launch arguments of running Chrome app processes locally for the headless
flag. The raw argument bytes are discarded after that check and are never logged,
added to history/observations or sent to Jev. Existing automation is not terminated.

## Data flow

Audio is required to use Apple's on-device English recognition. Relay does not
upload microphone audio. Literal dictation, clipboard contents, full AX trees,
window titles, screenshots and full OCR output are excluded from Jev requests.
Only masked instructions, recognized common controls, opaque local references,
action kinds and local boolean findings are sent. Copy verifies the clipboard
change counter without reading its contents. Task history lives in process
memory, not new history files. Old files from previous versions are not deleted.

Filtering is best effort: private content embedded outside recognized dictation
can escape masking. Destination apps still receive text you deliberately type
or send to them. TypeSafe's current service and privacy terms govern requests;
Relay cannot enforce the provider's retention policy.

## Boundaries and reporting

Send, submission, deletion, payment and other consequential operations can require
review; credential/security steps require the user. Arbitrary shell execution
is not an action. A global stop is Shift-Command-Escape. This cannot undo an
action already issued. Do not rely on preview software for unattended sensitive
work. Review results, and test with harmless content first.

Do not put keys, screenshots of private content, transcripts, clipboard data or
account details in a public issue. A private vulnerability-reporting channel has
not yet been configured. Do not submit sensitive reports through public issues;
the owner still needs to configure and document a private channel. No support
address has been invented.
