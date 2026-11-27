# Changelog

All notable changes to PickleScript are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Linux x86-64 self-hosted toolchain on the 0.2 line: a freestanding ELF
  writer and linker, SysV x86-64 lowering, POSIX runtime backends over raw
  syscalls, and cross-building from Windows. Verified on Ubuntu 26.04 with no
  C toolchain or libc; not yet released or tagged.

- A POSIX stream backend (`abi_stream_posix`) mirroring the Windows stream
  symbols, so `std.fs` append/read works on Linux.

### Changed

- The toolchain version now has a single source of truth in
  `compiler/version.pkl` and follows Semantic Versioning. Development builds
  carry a `-dev.N` pre-release identifier; only releases are tagged.

- The runtime archive is being retired. Programs are lowered with their import
  closure into one object, so `pklc build` links a program itself.

### Security

- The package manager no longer trusts the lockfile for install locations.
  Entries must name a package, version and module that match the registry
  response, and their paths are re-derived from that identity and confined to
  `.pickle/packages`; absolute paths, `..` segments and renamed modules are
  rejected.

- Downloads require a caller-supplied SHA-256 pin and an HTTPS URL (plain
  HTTP only on loopback). Redirects to another origin drop `Authorization`,
  `Cookie` and `Proxy-Authorization`, and response headers are never used as
  an integrity source.

- Manifest and lockfile names, versions and dependency edges are validated
  before use: reserved runtime module names are refused, generated TOML is
  escaped, bundled crates take precedence over generated maps, and every
  dependency must be reachable at a version satisfying both its recorded
  constraint and the manifest's.

## [0.1.0] - 2026-11-27

### Added

- The Windows x64 self-hosted PickleScript toolchain: compiler, CLI, package
  manager, test harness, PE linker, and the standalone `pklc` release driver.

[Unreleased]: https://github.com/pickle-foundation/Picklescript/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/pickle-foundation/Picklescript/releases/tag/v0.1.0
