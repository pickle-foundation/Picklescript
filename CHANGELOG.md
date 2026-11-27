# Changelog

All notable changes to PickleScript are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Linux x86-64 port work on the 0.2 line: an ELF64 relocatable-object writer,
  the SysV x86-64 calling convention, and POSIX runtime backends. This is not
  yet a released or verified Linux target.

### Changed

- The toolchain version now has a single source of truth in
  `compiler/version.pkl` and follows Semantic Versioning. Development builds
  carry a `-dev.N` pre-release identifier; only releases are tagged.

- The runtime archive is being retired. Programs are lowered with their import
  closure into one object, so `pklc build` links a program itself.

## [0.1.0] - 2026-11-27

### Added

- The Windows x64 self-hosted PickleScript toolchain: compiler, CLI, package
  manager, test harness, PE linker, and the standalone `pklc` release driver.

[Unreleased]: https://github.com/pickle-foundation/Picklescript/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/pickle-foundation/Picklescript/releases/tag/v0.1.0
