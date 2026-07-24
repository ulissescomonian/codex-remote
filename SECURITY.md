# Security Policy

Codex Remote starts and stops a local Codex process and briefly handles pairing
material. Security reports are welcome and should avoid exposing credentials or
live pairing data.

## Supported versions

Codex Remote is currently a Preview built around an experimental Codex CLI
surface. Security fixes are made on the latest revision of `main`; older builds
are not supported.

| Version | Security support |
| --- | --- |
| Latest `main` / latest Preview | Best effort |
| Older revisions and local builds | Not supported |

## Reporting a vulnerability

Use GitHub's private vulnerability reporting option in the repository's
**Security** tab when available. Do not disclose a vulnerability in a public
issue, discussion, pull request, or commit.

If private reporting is unavailable, open a public issue asking the maintainer
to establish a private channel. Do not include pairing codes, QR payloads,
tokens, `auth.json`, complete command output, process metadata, private paths,
logs, or screenshots containing sensitive data.

A useful private report includes:

- the affected Codex Remote and Codex CLI versions;
- macOS version and processor architecture;
- impact and affected trust boundary;
- minimal reproduction steps using synthetic data;
- whether the issue affects process execution, CLI discovery, pairing,
  updater recovery, status classification, or login items;
- a suggested mitigation, if known.

## Current boundaries

- Codex Remote delegates Remote Control behavior to the installed Codex CLI.
- It does not read `~/.codex/auth.json` or implement a separate remote protocol.
- Pairing codes and QR payloads exist only in memory and are discarded when the
  pairing window closes. Copying the manual code intentionally places it on the
  macOS clipboard.
- QR rendering is local; the complete Codex Remote Control workflow still uses
  the network through the Codex CLI and ChatGPT.
- Process execution uses direct executable URLs and separate arguments, with
  bounded timeouts and separated output streams.
- Stale-updater recovery is exceptional and fail-closed. It signals only an old
  standalone updater whose PID, owner, start time, arguments, executable, and
  release identity pass repeated validation.
- Local preferences contain settings such as polling interval and CLI override,
  not credentials or pairing material.
- The downloadable Preview is ad-hoc signed, not Developer ID signed, and not
  notarized by Apple.

These boundaries are not a substitute for privately reporting a suspected
vulnerability.
