# Picklescript

Picklescript is a self-hosted programming language and toolchain. This repository contains the Picklescript compiler, CLI, and runtime implementation (Picklescript-only).

For the legacy Rust bootstrap compiler, see [Picklescript-Legacy-Compiler](https://github.com/pickle-foundation/Picklescript-Legacy-Compiler).

## Layout

- `compiler/` - the self-hosted Picklescript compiler (plexer, resolver, checker, x64 back end, PE linker).
- `runtime/` - the runtime archive sources: GC engine, shadow registry, box/math/mapping helpers.
- `cli/` - the command-line drivers (build, run, test, rtlib archiver).
- `stdlib/` - the standard library.
- `tools/` - the qualification batteries and the self-host genesis seed (`tools/diff/selfhost/seed.exe`, committed).

## Verify a fresh clone

Everything needed to build and test the toolchain ships in this repository - no Rust
toolchain and no network access:

```
powershell -NoProfile -ExecutionPolicy Bypass -File tools\battery_lite.ps1
```

This rebuilds the test drivers from the committed seed, refreshes the runtime
archive if its inputs changed, then runs the compiler corpus (`compiler/*_test.pkl`,
19 modules) and the full runtime assert suite (`runtime/*_test.pkl`, 567 tests).
Warm wall time is roughly 15-20 minutes on a plain desktop.

## Build a driver by hand

```
tools\diff\selfhost\seed.exe cli\test.pkl tools\diff\rtlib.ar tools\diff\port\pklc_test.exe
tools\diff\port\pklc_test.exe compiler\x64_test.pkl tools\diff\rtlib.ar
exit 0 = pass
```


