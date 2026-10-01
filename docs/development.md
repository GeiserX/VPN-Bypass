# Development

## Building

See [Build from source](getting-started.md#build-from-source) and [Xcode](getting-started.md#xcode).

> **CI note:** The `test` job (`swift test`) requires **full Xcode** — XCTest ships only with Xcode, not with the Command Line Tools. CI runs on GitHub-hosted `macos-latest` runners (free and unlimited for public repos), which ship full Xcode, and selects the toolchain via the `maxim-lobanov/setup-xcode` action.

## Translations

The app ships in English, Spanish and French. The texts live in `Sources/VPNBypassCore/Resources/<language>.lproj/Localizable.strings`, keyed by the English text, and a new string needs a line in all three files. To check them:

```bash
python3 scripts/check-localizations.py
```

[The script](https://github.com/GeiserX/VPN-Bypass/blob/main/scripts/check-localizations.py) builds `VPNBypassCore` in a temporary directory with the compiler's `-emit-localized-strings` flag. The compiler then writes out every literal passed to `String(localized:)`, `Text`, `Button`, `.help` and the other localizable APIs, with the placeholder each interpolation becomes (`%lld` for an integer, `%@` for a string). The script fails when the Spanish or French file lacks one of those keys, or when a translation's placeholders differ from its key's. It skips keys with no letters, such as `%lld/%lld` or `8080`. Names that read the same in every language, such as `SOCKS5` or `example.com`, get a line whose value is the English text. CI runs the script after `swift test`.

The compiler only sees literals. A literal passed through a `String` parameter, or returned as a `String`, is shown as typed and never translated. Take a `LocalizedStringKey` instead, and the literal becomes a key.

## Contributing

Contributions are welcome! Here's how you can help:

1. **Report bugs** - Open an [issue](https://github.com/GeiserX/VPN-Bypass/issues) with details
2. **Suggest features** - Use the feature request template
3. **Submit PRs** - Fork, create a branch, and submit a pull request

Please read the issue templates before submitting.
