# Development and contributing

## Building

See [Build from source](getting-started.md#build-from-source) and [Xcode](getting-started.md#xcode).

> **CI note:** The `test` job (`swift test`) requires **full Xcode** — XCTest ships only with Xcode, not with the Command Line Tools. CI runs on GitHub-hosted `macos-latest` runners (free and unlimited for public repos), which ship full Xcode, and selects the toolchain via the `maxim-lobanov/setup-xcode` action.

## Contributing

Contributions are welcome! Here's how you can help:

1. **Report bugs** - Open an [issue](https://github.com/GeiserX/VPN-Bypass/issues) with details
2. **Suggest features** - Use the feature request template
3. **Submit PRs** - Fork, create a branch, and submit a pull request

Please read the issue templates before submitting.

## Badges

<p>
  <img src="https://img.shields.io/badge/Swift-5.9-orange?style=flat-square&logo=swift&logoColor=white" alt="Swift 5.9">
  <a href="https://codecov.io/gh/GeiserX/VPN-Bypass"><img src="https://codecov.io/gh/GeiserX/VPN-Bypass/graph/badge.svg" alt="codecov"></a>
</p>
