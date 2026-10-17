# Pk (pickled) language notes for the self-host port

Rules discovered while porting `compiler/src/emit.rs` -> `pickle/compiler/emit.pkl`.
These are hard constraints of the Pk language/compiler (5.1-era toolchain). Verify
each against a probe file before relying on it; some behaviors are known bugs.

## Match arms

- **Or-pattern alternatives may NOT bind names.** `case A(x) | B(x) -> ...` is a
  hard error ("an or-pattern alternative may not bind a name"). Allowed
  alternatives in an or-pattern are only literals, `_`, `some(_)`, `Tag(_)`.
  Split binding or-patterns into separate arms:

      case ClassMember.Init(b) -> this.walkBlock(b, ...)
      case ClassMember.Deinit(b) -> this.walkBlock(b, ...)

- **`case X -> return v` is a SYNTAX ERROR** (E0111 "expected an expression,
  found `?`"). Bare `return` cannot be a match-arm expression; wrap it in a
  block arm:

      case Ty.Fn(_, _) -> { return true }
      case _ -> { return none }

- Value-style `match` works; a `return` inside a *block arm* is fine:

      case none -> { this.bad(...); return none }

- Match arms produce values; direct-value arms auto-wrap into `Option` returns.

## Option / nullability checks

- **`x != none` and `x == none` are INVALID for ALL reference/option types.**
  The Pk type checker rejects them ("operator `Ne`/`Eq` requires comparable
  operands, found `Expr?` and `none`") — this applies to `int?`,
  `StaticFieldLoc?`, `IrTy?`, `string?`, `FnBody?`, `Expr?`, `Ty?`, etc. There
  is no `!= none` / `== none` on any option type.

  Is-none:
      if (let none = x) { ... }

  Is-some:
      if (let some(v) = x) { ... }
      if (let some(_) = x) { ... }          // value unused

  To fold into a boolean expression, precompute a flag:
      var b = false
      if (let some(_) = x) { b = true }
      if (p.rest || b) { ... }

- `if (let some(c) = o) { } else { }` and `if (let none = o) { return }` are the
  only option tests; assign-outside-of-branches on seeded vars works.
- **Auto-lift does NOT happen for explicit typed bindings from options.** A
  `var oname: string = ownerName` (ownerName: `string?`) is an E0308. Seeded
  local + `let some` unwrap:
      var oname = ""
      if (let some(on) = ownerName) { oname = on }

## Locals

- **ALWAYS seed a local at declaration.** A `var x: T` declared WITHOUT an
  initializer and assigned later miscompiles at runtime on Pk 5.1: reads return
  junk values for all types. Declare-then-reassign against a seeded value is fine.
  Idioms:
      var table: ClassTable = seedClassTable()
      var ret: Ty = Ty.Unknown
      var members = emptyClassMembers()
      var tramp = 0
      var caps: List<Capture> = emptyCaptures()
  If the value can't be unwrapped directly, seed then overwrite:
      var n = ""
      if (let some(s) = o) { n = s }
  A `var x = none` alone types as `none`; use a typed seed (`string? = none`) to
  declare an `Option` local.
- A local meant to hold an `IrTy` (e.g. from `this.irty(span)`, which returns
  `IrTy?`) must be seeded with a real value like `IrTy.Unit`, never a scalar
  like `-1`: a `-1` seed types the local as `int`, and `x = iv` then fails
  E0308 ("expected `int`, found `IrTy`"). The seed is never read on the none
  path because that path `return`s. (Same applies to any non-scalar enum-typed
  seed variable reassigned from an unwrapped option.)

## Strings & bytes

- **String `<` is NOT supported** ("operator `Lt` is not supported for `string`
  operands"). For lexicographic order, compare byte arrays:
      for (c in s) { out.push(c as int) }     // iteration yields byte; push needs `as int`

- No string slicing/subscript by range. `planName`-style "up to a byte value"
  loops are done with `for (c in name)` over bytes and `{c as char}` re-assembly.

## Collections

- **Empty lists**: `var l = [seed]; l.pop(); l` (the `[x]`/`pop()` idiom).
- **Empty maps**: `var m = { "::seed::": v }; m.remove("::seed::")` — `{}` alone
  may type as something else; always seed, and use a value that matches the map
  value type.
- `xs.insert(i, v)` and `xs.remove(at)` exist. `push`/`pop` exist.
- **`[]` as a call ARGUMENT is illegal** where a `List<T>` parameter is typed
  (E0308 "`List<?>` does not satisfy `List<IrTy>`"/"`List<int>`"). Use the seeded
  helpers instead: `externCallVoid("pickle_print_newline", emptyIrTys(),
  emptyInts())`, `externCallT1(sym, emptyIrTys(), IrTy.Ptr, emptyInts())`.
  The `[x]; pop()` idiom is only for declaring list *vars*, not empty literals.
- Lists/maps are passed by reference, so a `scope: List<Map<string,bool>>`
  passed into walkers mutates in place (mirrors Rust `&mut Vec`).

## Calls

- A method call whose return value you ignore can be a bare statement
  (`this.bad(...)`, `this.registerImplements(...)`).
- `let` inside expressions (`let m = {...}`) is allowed in helpers.
- **`externCallT1(symbol, params, ret, args)` returns a plain `int` (a temp
  slot), NOT an option** — never guard its result with `let none`/`let some`
  (that is an E0111 "`none` pattern cannot match a value of type `int`"). Bind
  it directly: `var created = this.externCallT1("pickle_class_new", [IrTy.Int,
  IrTy.Int], IrTy.Ptr, [cidT, nT])`. Same class: `externId` returns `int`.
  Only T-returning helpers like `expr`, `elemRep`, `mapTy`, `tyOf` return `T?`.

## Misc

- `hasVar` is a FREE FUNCTION `hasVar(t: Ty)` (ty.pkl), NOT a method — call it
  `hasVar(a)` not `a.hasVar()`.
- `ClassTable.generics` is `List<string>` (bare names, not `GenericParam`
  structs) — indexing yields a string: `map[table.generics[gi]] = args[gi]`.
- `for (item in list)` binds values, not indices. Use an index var for positions.
- `continue`/`break` are supported inside loops.
- Nested `match` as a statement inside a match-arm block is fine.
- An `enum` variant's fields are accessed positionally in `case` patterns and by
  name (`m.field`) on instances.

## Keywords & names

- **`from` is a RESERVED WORD.** It cannot be a parameter name (`fn convert(...,
  from: Ty, ...)` fails E0111 "expected identifier for parameter") and the bad
  parse can cascade E0351 "undeclared name" into *later* functions' `let some`
  binders. Rename such params (e.g. `src`).

## If-chains unify branch values

- Even in statement position, every arm of an `if`/`else if`/`else` chain must
  end with the SAME typed final expression (E0310 "branches have mismatched
  types"). An empty arm is `Unit`, an `x = e` arm has the type of `e` (bool for
  `b = true`, int for `i = ...`). Any mutation-only chains mixing bool/int arms
  fail. Fix: end every arm with the same-typed no-op, e.g. a self-assignment
  `i = i` (an int-typed assignment), or restructure so arms end in `break`.

## No narrowing after a none-guard

- After `if (let none = xO) { return none }`, `var y = xO` STILL types `y` as
  the option type (`ElemRep?` etc.) — there is no null-narrowing. E0308 fires
  wherever the non-option value is then required. Re-wrap against a concrete
  default using the `fieldRead` idiom:
      var rep = ElemRep.ptr()          // concrete default of the value type
      if (let some(r) = repO) { rep = r }
- `match`'s scrutinee must be a NON-option value. Matching a `Ty?` with
  `case Ty.Ptr(..)` is an error ("patterns on an option value must be
  `some(v)`, `none`, or `_`"); wrap: `if (let some(t) = ot) { match (t) {...} }`.

## No narrowing for `List`/`int` option returns either

- `if (let none = callArgs) { return none }` does NOT narrow a
  `List<int>? = marshal(...)` result — `var callArgs` is still `List<int>?`
  afterward (same bug family as the `ElemRep?` case). Re-wrap against a
  concrete `emptyInts()`:

      var callArgs = emptyInts()
      var ca = this.marshalMethodArgs(e, fid, args, receiver)
      if (let some(c) = ca) { callArgs = c } else { return none }

- Same for scalar options like `cmpZero(...) -> int?`: bind
  `var isZero = -1; if (let some(z) = zO) { isZero = z } else { return none }`.

## Statement-style match arms still must agree in type

- E0310 "match arms produce inconsistent types" applies to mutation-style arms
  too, not just value matches. `case A -> x = 0` (int) vs `case _ -> ok = false`
  (bool) fails. Fix: end every arm with a same-typed assignment; e.g. make each
  arm finish with `ok = true` / `ok = false`.

## No `Ty.Unit` variant

- There is no `Ty.Unit` in the checked-type enum. Rust's unit-ish checks seed a
  `Ty` local with nil/empty; use `Ty.None` or `Ty.Empty` (both `mapTy` to
  `IrTy.Unit`). A seed of `Ty.Unit` is an E0352 "no member `Unit` on type `Ty`".

## Nested options from `Map<string, T?>.get`

- Reading a map whose *value* is itself an option (e.g. `lambdaOwners:
  Map<string, int?>`) with `.get(k)` yields a doubly-nested option. Bound with
  `if (let some(o) = m.get(k))` the inner `o` unwraps one level, giving the
  `int?` value directly; the double-option local itself type-checks and is safe.
  (Alternative: `.has(k)` + index read `m[k]`, which returns the element type
  `int?` directly.)

## Statement matches tolerate a `{}` arm next to assignment arms

- A used-as-statement `match` whose arms mix `case _ -> {}` (empty, unit) with
  `case X -> flag = true` (bool ending) passes the checker even though the same
  mix in an `if`/`else if`/`else` chain would be an E0310. Empty-block arms are
  accepted beside assignment-ending arms in matches.

## Generics / monomorphization

- `anyHasVar(ts: List<Ty>) -> bool` is a free function in `ty.pkl` (like
  `hasVar`): use it for "any of these type args has a free variable" checks
  instead of a manual loop.
- The `instantiations: Map<string, int>` (generic-function fid cache) key is
  the existing `instKey(name, args)` helper (renders `name<b1, b2>`); its
  lookup and insert must both use `instKey(name, argTys)` — the same builder
  `classInstByArgs` uses. `instKey`'s docstring already covers the
  `(String, Vec<Ty>)` role.
- `instantiate_generic_fn` registers a placeholder `IrFunc` (empty params,
  `IrTy.Unit` ret, empty slots/blocks) exactly like `pushClassFunc`, then keyed
  registrations make the later `fidList` body-build fill it in:
  `fsource[fid] = FnSource.TopLevel(f)`, `finfo[fid] = CallableInfo(...)`,
  `srcParamTys[fid] = <substituted param tys>`, `instantonSubst[fid] = map`,
  `instantiations[instKey(...)] = fid`. Only `finfo`/`srcParamTys` get
  substituted types; the function's own `name`/`generics` stay original.
- Rust's Debug format `{target:?}` of `FuncId(n)` renders as `FuncId(n)`; port
  bad messages literally: `"no signature recorded for instantiated function
  FuncId(" + str(target) + ")"`.
- `generic_call` must check `resolved.types` FIRST (class/struct ctor path) and
  only then `resolved.fns`; reuse `userCallableFirst(name)` for the Rust
  `infos.iter().find(|c| !(c.span.file.0 == 0 && c.span.end == 0))` lookup.
- `genericFnArgValue` returns `int?` with `Ok(None)` folded to silent `none`
  (caller `borrowArg` falls through to the normal argument path) and
  `Ok(Some(t))` to `t`. A failing inner `genericFnValueFor` also collapses to
  `none` (a `bad` has already been emitted), losing Rust's error/None
  distinction — accept that loss in follow-up callers.

## Match-arm tails must be same-typed across VALUE matches

- In a value-position match (not just statement matches), every arm's tail
  MUST end with the same Rust-host type — mixing `bool` and `string`
  assignment tails is an E0310 even though both arms are statements
  (`case Binding(nm, _) -> nm = ...` vs `case _ -> ok = false`). Verified in
  `lowerEnumMatchTable`'s catch-all detection. Fix: end each arm with the
  same-typed assignment, e.g. set the boolean LAST after doing the string work
  in earlier lines of the block arm:
      case Pattern.Binding(nm, _) -> {
          bindName = nm
          isCatchAll = true
      }
      case _ -> {
          isCatchAll = true
      }

## Floats expose no `trunc` — use an int round-trip

- Pk has no `trunc`/`floor`/`ceil` on `float` anywhere in the codebase. Rust's
  check that a float literal pattern represents an integer
  (`value == value.trunc() && value >= i64::MIN as f64 && value <= i64::MAX as
  f64`) cannot be mirrored directly. In `patternLiteralTemp` use the VM
  round-trip instead (probe-verified; `(float as int)` truncates toward zero
  on the VM, back-conversion is exact for integral values):
      var iv = value as int
      var back = iv as float
      if (back == value) { ... }   // else bad: "float pattern does not represent an integer"

## Match-result slots are `Ptr` when the result type is an option

- `matchExpr`'s result slot is given to `matchArmBody`, which must wrap scalar
  arm values into the option when the slot's IR type is `Ptr`. Derived from
  `IrTyTag`: `matchArmBody` compares `irTyTag(this.fslots[slot]) ==
  irTyTag(IrTy.Ptr)` and calls `optionWrap` only then — mirroring Rust's
  `lift_to_irfig`/`IrTy::Ptr` check. Enumerated results never need a slot
  (`matchResultNeedsSlot` returns false for enums because their variant IR
  types are scalar tags resolved at arm build time).
## New gotchas (nested patterns + implicit-this port)
- some(x) is PATTERN-ONLY syntax: you cannot write some(v) as an expression. To pass a present-option value into an int? param pass the int directly (auto-lifts), e.g. `this.callMethod(e, fid, args, thV)`.
- When a Pk helper returns int? and must distinguish 'no condition' from 'emission error', return the sentinel -1 for 'no condition' (temps/slots/blocks are always >= 0); never collide with `none` = error.
- exprKindIdentName(callee) gives the ident name; bare instance-method calls must be resolved on the implicit receiver BEFORE the isFnDispatchable check (mirror Rust call).

## Personality contract (port must keep the jokes)
- The crash stanza (`The pickle jar cracked.` / E9999) and the hidden `pickle jar` diagnostics live in the Rust CLI host (cli/src/iced.rs + main.rs), not the compiler, because argv & process signals are host-side. Their exact texts are pinned by #[cfg(test)] in iced.rs - if they change there, update this note and anywhere the ported toolchain prints the same surface.
- When the self-hosted compiler becomes the engine behind the CLI, it emits diagnostics via the normal sink, never the stanza; E9999 stays the host's job for hard faults (SEH/signal/panic) only.

## Exceptions in the port (this session's port feed)
- `throw "msg"`, `try { } catch (e) { } finally { }` are wired through the front
  (`Stmt::Try`/`Stmt::Throw`, see `compiler/src/front.rs` `lowerTry`) and the
  runtime `exception.rs`. Tests: `tests/pickle/exception_test.pkl` (+
  `exception_paths_test.pkl`, `exception_gc_test.pkl`,
  `import_exception_test.pkl`, `map_field_stress_main.pkl`).
- `try` used as a tail VALUE works: the block's value arm is the result
  (`guarded()` in exception_test.pkl). `catch (e)` binds the payload as
  `string`.
- The selfhost emitter STILL lowers `finally`/`catch` through the old
  `catchCode`/`finallyCode` path; keep `performExit`/`exitThroughFinallys`
  (jump-through-finallys) in sync with `emit.rs` when new stmts land.
- No `.fname()` on `IrFunc` in the selfhost `IrModule`: read
  `this.irModule.funcs[fid].name` (a `string` field on the struct).

## Auto-GC corruption diagnostics (in-progress)
- Repro (deterministic under auto-GC): `pickle-cli run
  pickle\cli\ir_one.pkl -- tests\pickle\import_exception_test.pkl` with
  `PKL_NO_AUTO_GC=1`; the forced `gcCollect(true)` immediately after
  `buildFunc(fidList[7])` in `buildAll` gives, 8/8: `internal error: misaligned
  pointer dereference ... 0x3d at runtime\src\map.rs:128` (a garbage key
  past a rehash of a map whose entries buffer was freed by an earlier sweep).
- Facts established so far (see docs/05-memory.md "Diagnostics env vars"):
  - Selfhost vs native PickleIR texts are byte-identical (4243 vs 4244 lines;
    one trailing blank) for the flaky target.
  - Every managed-typed def/argument has a JIT shadow cell (no `UNROOTED-*`
    hits).
  - Class managed-field masks registered by native vs selfhost for the same
    modules: 109/109 identical.
  - With `PKL_GC_TRACE=1`, no object the sweep frees is referenced by any live
    shadow-frame cell or static root (`SWEEP-KILLED` = 0 across all classes).
  - `PKL_PIN_MAPS=1` removes the 0x3d crash entirely: the freed-and-reused
    block is a map (or its entries buffer). Under pins the run dies later in
    a separate path (iced frames near `pkl_Emitter_forStmt`/
    `pickle_tuple_set_field`), so stale references elsewhere remain possible.
- Working hypothesis: a map reachable only from a non-frame/native holder
  (JIT-internal or an `extern` helper local that allocates) during the emitting
  loop. Next: audit allocating natives for map locals held across `alloc`,
  or pin map sweeps for the whole emit and validate the 72-run blast.
- **RESOLVED 2026-09-28 (CLOSED).** Root cause: the armed forced
  `gcCollect(true)` in `buildAll` after `buildFunc(fidList[7])` adversarially
  timed a sweep that preserved a string whose block had been freed and reused,
  so its `deep_hash` key went stale and rehashed into a freed map entries
  buffer. Fixes kept (native): JIT `LoadSlot` write-through + `deep_hash`
  FREE_SENTINEL/plausibility identity-hash guards in `map.rs`. The forced
  collect and all chase-the-corruption diagnostics (`PKL_PIN_MAPS`,
  `PKL_ALL_KLED`, `PKL_CLS_DUMP`, `PKL_SWEPT`, `PKL_LIVE_EDGES`, `PKL_CENSUS`)
  were removed. NATURAL (no env) `PKL_NO_AUTO_GC=1` runs are fully
  deterministic: ARM 8/8 at exit 0, zero stderr; full 11-gate battery green on
  2026-09-28. Distinct, still-OPEN nondeterminism: the grouping variation
  (4 vs 5 `pickle_exc_pending` checks in `pickle_main`, ~1-in-40 under load),
  mitigated by `selfhost_ir_stable`; unaffected by this commit.
