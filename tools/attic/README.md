# tools/attic

Parked sources kept for historical reference. Nothing here is imported by a
module, built by a gate, or invoked by a script under `tools/`; `git grep` finds
no reference to these module names. They are not deleted because the office
ledgers (`HANDOFF.md`, `MEMORY.md`, `MEMORIES.md`, `NOTES.md`) cite some of them
as the drivers used during the early port phases.

## cli/ - historical `cli` entry points

Each file is a standalone `main` that was compiled ad hoc with the self-host
seed:

```
tools\diff\selfhost\seed.exe tools\attic\cli\<name>.pkl tools\diff\rtlib.ar <out.exe>
```

| file | module | what it did |
| --- | --- | --- |
| `check_rej.pkl` | `cli.check_rej` | Checker reject driver: lex/parse/resolve/check a file, print the `classifyMessage` E-codes. |
| `res_rej.pkl` | `cli.res_rej` | Resolver reject driver (E0201-E0224 codes). |
| `rej.pkl` | `cli.rej` | Parser reject driver (token describe via `parseutil.describeTok`). |
| `dump.pkl` | `cli.dump` | Frontend + `emitIr` + `x64LowerModule`/`x64Dump` for one file. |
| `gen2_diag.pkl` | `cli.gen2_diag` | Frontend + `emitIr` diagnostic dump. |
| `gen2_stop0.pkl` | `cli.gen2_stop0` | Frontend + `emitIr`, prints `ok<N>` / `irfail0` / `irfail1`. |
| `gen2_stopA.pkl` | `cli.gen2_stopA` | Frontend-only stop probe. |
| `ir_one.pkl` | `cli.irone` | `frontendChecked` + `emitIr`, prints the IR module. |
| `run_one_oracle.pkl` | `cli.runoneoracle` | Frontend + `emitIr`, writes IR and IRX (oracle capture). |
| `run_self.pkl` | `cli.runself` | Frontend + `emitIr`, writes IR and IRX. |

`cli/run_one.pkl` deliberately stayed in `cli/`: it declares `module cli.runone`
and `cli/run_one_self.pkl` (a live battery-prep driver) imports it.

## Reviving one

Move the file back into `cli/` first. The module declarations are still
`cli.<name>`, and the loader resolves modules from the source roots passed to
the build, so a parked copy outside `cli/` will not resolve its own imports
reliably. Then build it with the seed as above.
