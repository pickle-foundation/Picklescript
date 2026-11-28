# Changelog

All notable changes to PickleScript are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Linux x86-64 self-hosted toolchain on the 0.2 line: a freestanding ELF
  writer and linker, SysV x86-64 lowering, POSIX runtime backends over raw
  syscalls, and cross-building from Windows. Verified on Ubuntu 26.04 with no
  C toolchain or libc: the cross-built compiler is 10,228,624 bytes, SHA-256
  `FB5343AD17C5BE5C8A3A4BAEB28FB737D741213AAFACEB36443AA7888BD8402F`, and
  its self-rebuild is byte-identical. Not yet released or tagged.

- A POSIX stream backend (`abi_stream_posix`) mirroring the Windows stream
  symbols, so `std.fs` append/read works on Linux.

- Linux AArch64 (ARM64) self-hosted toolchain: an AArch64 backend over the
  same IR, an AArch64 ELF writer and linker with native stubs, and
  `build --target linux-arm64` in both drivers. The cross-built compiler and
  the compiler it builds from its own source are byte-identical (6,022,032
  bytes, SHA-256
  `DD375CF35E43DFF35C905DB558245C35CD21A56176C12846D18CD385C162CFD1`),
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

- AArch64 `thread_spawn` passed the closure environment in `x1` while the
  closure reads it from `x0`, so the first spawn segfaulted. The clone stub
  also put `child_tid` in the `tls` slot and tested stale condition flags
  after `svc`, so `thread_join` could unmap a live thread's stack. The stub
  now follows the AArch64 `clone` argument order and compares the result.

- `thread_join` on Linux waited on the child-only TID word with a private
  futex. The child writes that word only after it starts, so the parent could
  read zero and unmap a live stack; the kernel's exit wake is shared, so a
  private wait never returned either. Both TID pointers now name handle word
  0, which `CLONE_PARENT_SETTID` writes before `clone` returns, and the wait
  is a shared `FUTEX_WAIT`. The zero ctid had made join return immediately on
  x86-64, which hid the race until a sleeping thread outlived the join.

- Unary float negation on AArch64 subtracted the IEEE-754 bit pattern from
  zero, so negating `1.0` produced `-4.0`. It now uses `fneg`.

- A function with more than eight float parameters loaded a stack-passed
  float through `d0` before saving the register arguments, clobbering the
  first parameter. Register arguments are saved first.

- AArch64 `sdiv` does not trap: a zero divisor returned zero and
  `INT64_MIN / -1` returned `INT64_MIN`, where x86-64 raises `SIGFPE`. Both
  cases now trap, matching the IR optimizer's assumption that they do.

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
