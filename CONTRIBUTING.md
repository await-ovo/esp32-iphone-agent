# Contributing

Issues and pull requests are welcome. Keep changes small and focused, and match the surrounding code.

Before sending a change, run the checks for what you touched:

```bash
# Midscene runtime (Node.js 22 and pnpm 10.11.0)
pnpm --dir ios/Midscene install --frozen-lockfile
pnpm --dir ios/Midscene test
pnpm --dir ios/Midscene build
# app (Xcode 27+ and an iOS 27+ simulator)
(cd ios && xcodegen && xcodebuild test -scheme IPhoneAgent -destination 'platform=iOS Simulator,name=iPhone 17 Pro')
# firmware
hardware/flash.sh --build-only && make -C hardware/tests
```

Never commit secrets: `ios/Config/Local.xcconfig` is git-ignored on purpose.
Review and Diagnostics export raw run data; Settings › Privacy provides a separate redacted export.
See [Export runs for agent review](docs/run-data-export.md), and check archives before attaching them to an issue.
