# GeckoKit

The Gecko app's pure, dependency-free helpers (no SwiftUI / bridge), split into a
SwiftPM package so they can be unit-tested. The very same source files are
compiled straight into the app by `build-app.sh` (it globs
`GeckoKit/Sources/GeckoKit/*.swift` alongside `Sources/*.swift`), so there is one
source of truth — the tests exercise exactly what ships.

- `MessageFormatting.swift` — `linkifiedBody` (URL/email link detection) and
  `messageRuns` (blockquote line grouping). Foundation-only.
- `ImageEncoding.swift` — `avatarPNG` (re-encode a picked image to PNG before the
  bridge publishes it). UIKit-only, so it's `#if canImport(UIKit)`-gated.

## Running the tests

```sh
# Fast: formatting helpers on the host (macOS). UIKit-only tests are skipped.
swift test                       # from this dir, or: --package-path ios/app/GeckoKit

# Full: everything, incl. the UIKit image-encoding tests, on the Simulator.
xcodebuild test -scheme GeckoKit-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```
