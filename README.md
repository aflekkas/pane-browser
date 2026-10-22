<div align="center">
  <h1>Pane</h1>
  <p>A minimal, native WebKit browser for macOS. Sidebar, spaces, content.</p>
</div>

> [!IMPORTANT]
> Pane is a fork of [Ora Browser](https://github.com/the-ora/browser) (GPL-3.0), rebranded and extended
> with features from the original [Pane](https://github.com/aflekkas/pane-browser/tree/legacy) project.
> It is not affiliated with or endorsed by the Ora team. The rest of this README is inherited from Ora.
<br/>
<p align="center">
  <a href="https://www.apple.com/macos/"><img src="https://badgen.net/badge/macOS/15+/blue" alt="macOS 15+"></a>
  <a href="https://developer.apple.com/xcode/"><img src="https://badgen.net/badge/Xcode/15+/blue" alt="Xcode 15+"></a>
  <a href="https://swift.org"><img src="https://badgen.net/badge/Swift/5.9/orange" alt="Swift 5.9"></a>
  <a href="https://brew.sh"><img src="https://badgen.net/badge/Homebrew/used/yellow" alt="Homebrew"></a>
  <a href="LICENSE"><img src="https://badgen.net/badge/License/GPL-3.0/green" alt="GPL-3.0"></a>
</p>

> [!NOTE]
> Ora is still in active development and is not ready for daily use yet.

## Overview

Ora is a macOS browser built with SwiftUI, AppKit, and WebKit. The project aims for a native, low-friction browsing experience without layering on unnecessary product surface area.

## Highlights

- Native macOS UI
- WebKit-based browsing
- Built-in content blocking and privacy protections
- Search engine customization
- URL suggestions and quick launcher
- Developer-focused features

## Quick Start

```bash
git clone https://github.com/aflekkas/pane-browser.git
cd pane-browser
./scripts/setup.sh
open Pane.xcodeproj
```

The setup script installs required tooling, installs git hooks, and regenerates the Xcode project.

## Development

- Main app target: `ora`
- Project configuration is managed with `XcodeGen` in `project.yml`
- Regenerate the project after config changes with `xcodegen`
- Run tests in Xcode with `Product > Test` or via `xcodebuild test -scheme ora -destination "platform=macOS"`

## Docs

- [Contributing](CONTRIBUTING.md)
- [Roadmap](ROADMAP.md)
- [Wiki](https://github.com/the-ora/browser/wiki)
- [Security](SECURITY.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)

## Links

- [Website](https://www.orabrowser.com)
- [Discord](https://discord.gg/9aZWH52Zjm)
- [GitHub Sponsors](https://github.com/sponsors/the-ora)
- [Buy Me a Coffee](https://buymeacoffee.com/orabrowser)
- [X / Twitter](https://x.com/orabrowser)

## License

Ora Browser is licensed under [GPL-3.0](LICENSE). Third-party libraries used by this project are licensed under their own open-source licenses.
