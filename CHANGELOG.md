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

- Linux AArch64 (ARM64) self-hosted toolchain: an AArch64 backend over the
  same IR, an AArch64 ELF writer and linker with native stubs, and
  `build --target linux-arm64` in both drivers. The cross-built compiler and
  the compiler it builds from its own source are byte-identical (6,013,840
  bytes, SHA-256
  `8BBA394C801395298E0B08B3C314ECF7DC8DB2280D69282092FDD59274FCA927`),
  so ARM64 reaches its own fixed point. Verified under `qemu-aarch64` only.

- `runtime.abi_sysno` now owns every Linux syscall number, argument shape and
  arch-specific open flag, with separate x86-64 and AArch64 bodies. A module
  may also ship as `<name>_<platform>_<arch>.pkl`, and `runtime.abi_sys`
  exports `SYS_ARCH` so the CLI can default to the host's instruction set.

### Changed

- The toolchain version now has a single source of truth in
  `compiler/version.pkl` and follows Semantic Versioning. Development builds
  carry a `-dev.N` pre-release identifier; only releases are tagged.

- The runtime archive is being retired. Programs are lowered with their import
  closure into one object, so `pklc build` links a program itself.

### Fixed

- AArch64 integer comparisons used the float condition codes, so `<` and `<=`
  against a negative value behaved like an unsigned compare and loops such as
  `while (i < 0)` never ran. Float compares keep the `MI`/`LS` tests that
  `fcmp` needs.

- `list_dir` on AArch64 opened directories with the x86-64 `O_DIRECTORY`
  value (`0x10000`), which is `O_DIRECT` on that architecture; every listing
  failed with `EINVAL`. The flag now comes from the per-arch syscall seam.

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
