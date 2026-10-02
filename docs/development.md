# Development

## Building

See [Build from source](getting-started.md#build-from-source) and [Xcode](getting-started.md#xcode).

> **CI note:** The `test` job (`swift test`) requires **full Xcode** — XCTest ships only with Xcode, not with the Command Line Tools. CI runs on GitHub-hosted `macos-latest` runners (free and unlimited for public repos), which ship full Xcode, and selects the toolchain via the `maxim-lobanov/setup-xcode` action.

## Translations

The app ships in English, Spanish and French. The texts live in `Sources/VPNBypassCore/Resources/<language>.lproj/Localizable.strings`, keyed by the English text, and a new string needs a line in all three files. To check them:

```bash
python3 scripts/check-localizations.py
```

[The script](https://github.com/GeiserX/VPN-Bypass/blob/main/scripts/check-localizations.py) builds `VPNBypassCore` in a temporary directory with the compiler's `-emit-localized-strings` flag. The compiler then writes out every literal passed to `String(localized:)`, `Text`, `Button`, `.help` and the other localizable APIs, with the placeholder each interpolation becomes (`%lld` for an integer, `%@` for a string). The script fails when the Spanish or French file lacks one of those keys, or when a translation's placeholders differ from its key's. It also fails when the English, Spanish or French file has a key that no source file uses. Such a key means a lookup went back to a plain literal, or a string was removed and its line was not. Restore the lookup, or delete the line from all three files. It skips keys with no letters, such as `%lld/%lld` or `8080`. Names that read the same in every language, such as `SOCKS5` or `example.com`, get a line whose value is the English text. CI runs the script after `swift test`.

The compiler only sees literals. A literal passed through a `String` parameter, or returned as a `String`, is shown as typed and never translated. Take a `LocalizedStringKey` instead, and the literal becomes a key.

## Screenshots

The images in `docs/images/screenshots/` are offscreen renders of the real views with fixed, made-up state: WireGuard on `utun4`, four services and two domains, addresses from the documentation ranges. `Tests/VPNBypassTests/DocScreenshotsTests.swift` draws them and is skipped unless `VPNB_DOC_SCREENSHOTS` names an output directory:

```bash
VPNB_DOC_SCREENSHOTS=/tmp/shots swift test --filter DocScreenshotsTests
pngquant --quality 95-100 --speed 1 --force --ext .png /tmp/shots/*.png
```

Run it on a Mac with a 2x display, since the images are 2x. Each window draws as the key window of the active app, in the dark appearance, so the traffic lights and switches are in colour even when the test runs over ssh. A test fails if the close button comes out grey. Copy the files over the old ones and read each one before you commit it. Re-render after a change to any view the images show.

## Tests that open a port

A test that starts a TCP listener and connects a client to it takes the port from `TestPorts.nextListenPort()` in [`Tests/VPNBypassTests/TestPorts.swift`](https://github.com/GeiserX/VPN-Bypass/blob/main/Tests/VPNBypassTests/TestPorts.swift), never port 0 and never a fixed number. Port 0 picks from the range client sockets take their source ports from, so a listener can land on an old client's port and the next connect fails with EADDRINUSE. A fixed port fails whenever another process holds it. The helper hands out each port in 20000-48999 once per run, below that range and outside the 18000-18999 range the app's route listeners use, and binds it first to check it is free. A listener nothing connects to can stay on port 0, as `LoopbackPeerAuthTests` and `testPortZeroReportsTheAssignedPort` do.

## Contributing

Contributions are welcome! Here's how you can help:

1. **Report bugs** - Open an [issue](https://github.com/GeiserX/VPN-Bypass/issues) with details
2. **Suggest features** - Use the feature request template
3. **Submit PRs** - Fork, create a branch, and submit a pull request

Please read the issue templates before submitting.
