# Contributing to Codex Remote

Codex Remote favors native macOS behavior, explicit daemon states, bounded
process execution, and conservative handling of temporary pairing material.
Changes must keep the Codex CLI behind injectable services and must never make
tests mutate a user's real Remote Control daemon.

## Development requirements

- macOS 14 or later
- Xcode or Command Line Tools with Swift 5.9 support
- Apple Silicon for the current Preview distribution path
- Codex CLI only for optional manual testing; automated tests use fakes

## Build and validation

Run from the repository root:

```bash
swift build
swift test
swift build -c release
make bundle
plutil -lint .build/CodexRemote.app/Contents/Info.plist
codesign --verify --deep --strict .build/CodexRemote.app
```

Useful targets:

```bash
make build
make test
make bundle
make dmg
make run
make clean
```

`make bundle` builds the Release executable, assembles `.build/CodexRemote.app`,
includes the icon and plist, applies a local ad-hoc signature, and verifies the
bundle. Ad-hoc signing is not Apple Developer ID signing and does not provide
notarization or Gatekeeper trust.

## Preview DMG

Create the local distribution artifacts with:

```bash
make dmg
(cd dist && shasum -a 256 -c CodexRemote-1.0-arm64.dmg.sha256)
```

The DMG contains `CodexRemote.app` and an `/Applications` shortcut. The script
verifies the bundle identifier, executable architecture, code signature, disk
image, and checksum before publishing files into `dist/`. Generated apps,
DMGs, checksums, build products, and signing material must not be committed.

The current Preview is locally signed and not notarized. Documentation may
explain Finder's **Open** or **System Settings → Privacy & Security → Open
Anyway**, but must never recommend disabling Gatekeeper or removing quarantine
metadata globally.

## Architecture and invariants

| Path | Responsibility |
| --- | --- |
| `Sources/CodexRemote/Domain` | Pure models and protocols |
| `Sources/CodexRemote/Services` | CLI discovery, process execution, daemon control, recovery, QR, and login items |
| `Sources/CodexRemote/App` | Main-actor state, lifecycle, preferences, and recovery policy |
| `Sources/CodexRemote/Views` | Menu bar, pairing, and settings UI |
| `Tests/CodexRemoteTests` | Synthetic tests that never mutate the real daemon |

Preserve these contracts:

- launch the Codex executable directly with separate arguments; never build a
  shell command;
- apply timeouts and keep stdout and stderr separate;
- use `codex app-server daemon version` as the replaceable local status probe;
- serialize mutable Start, Stop, Restart, and Pair operations;
- keep a manual Stop authoritative for the current app session;
- retain the 30-second independent recovery confirmation and fail-closed
  updater identity checks;
- never read `~/.codex/auth.json` or persist pairing codes, QR payloads, tokens,
  or raw command output;
- keep login-at-startup integration on `SMAppService`.

## Making a change

1. Read `AGENTS.md`, `docs/01-product-plan.md`, and `docs/02-architecture.md`.
2. Identify the affected process, daemon-state, recovery, pairing, or login-item
   contract before editing.
3. Add regression coverage with fake services and synthetic inputs.
4. Run targeted tests followed by the complete validation gates.
5. Review source, logs, fixtures, app bundles, and DMGs for secrets and private
   workstation paths.
6. Update evergreen documentation and `docs/03-validation.md` when validated
   behavior or the distribution record changes.

## Pull request checklist

- [ ] Scope and user-visible behavior are explained.
- [ ] No test invokes real `remote-control start`, `stop`, or `pair` commands.
- [ ] Pairing material and command output remain memory-only and redacted.
- [ ] Process calls remain direct, bounded, and shell-free.
- [ ] Recovery remains fail-closed and manual Stop remains authoritative.
- [ ] `swift test` and the Release build pass.
- [ ] The packaged bundle validates when distribution files are affected.
- [ ] Documentation does not imply Developer ID signing or notarization.

Report suspected vulnerabilities according to [SECURITY.md](SECURITY.md), not
through a public issue or pull request.
