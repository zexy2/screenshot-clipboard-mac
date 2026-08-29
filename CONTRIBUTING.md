# Contributing

Thanks for taking the time to improve Screenshot Clipboard.

## Before opening an issue

Search existing issues first. For a bug, include a minimal reproduction,
macOS version, Mac architecture, affected feature, and permission state. Never
publish screenshots containing private conversations, credentials, tokens, or
personal data.

## Local setup

```bash
git clone https://github.com/zexy2/screenshot-clipboard-mac.git
cd screenshot-clipboard-mac
./Scripts/check.sh
```

There is no package manager or third-party dependency install. The project is
built directly with the macOS Swift toolchain.

## Pull requests

- Keep changes focused and explain the user-visible effect.
- Preserve the minimum macOS version unless the change requires a deliberate
  compatibility decision.
- Do not add API keys, account data, generated build products, or personal
  screenshots.
- Update the README or troubleshooting docs when behavior or permissions
  change.
- Add or update tests/checks when a deterministic test is possible.
- Run `./Scripts/check.sh` before submitting.
- Describe any manual UI test that could not run in CI.

## Review standard

Reviewers will look for correctness, failure handling, privacy impact,
Accessibility scope, compatibility with macOS 13+, and whether the change
keeps the helper responsive under screenshot bursts.

## Commit messages

Use a short imperative subject, for example:

```text
Fix stale clipboard data after screenshot capture
```
