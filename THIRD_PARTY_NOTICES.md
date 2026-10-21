# Dependencies and licensing inventory

The Swift package declares **no external SwiftPM dependencies**. There are no
vendored libraries, model weights, fonts, images, recordings or third-party
source archives in this release candidate. No Package.resolved is required.

Runtime imports are Apple-provided frameworks: Foundation, AppKit, SwiftUI,
ApplicationServices, Carbon, AVFoundation, Speech, ScreenCaptureKit, Vision,
Security, LocalAuthentication and Combine. They are linked from the installed
macOS SDK; copies of those frameworks are not redistributed here. Use of the
SDK and distribution of signed/notarized binaries remain subject to Apple's
applicable developer terms. Source compatibility has been tested on Apple
Silicon only; no universal binary is included.

Jev/TypeSafe is an optional external dependency for general planning. Supported
direct commands work without configuring a key.
It is accessed by HTTPS; no TypeSafe SDK, service code or shared credential is
bundled. Users supply their own account and are responsible for the service's
terms and usage charges. A proposed project license does not license that
service or Apple software.

The GitHub Actions workflow references the official actions/checkout action
only for CI. Its implementation is not vendored in this package. Review CI
permissions and third-party action versions before enabling it publicly.

License status: MIT is proposed in LICENSE.proposed. The rights holder and
license decision remain unconfirmed. This candidate must not be described
as an already licensed open-source release until a final LICENSE is added.

Inventory date: 2026-10-19. This is a source/dependency inventory, not an
independent legal opinion or an assertion of ownership over generated code.
