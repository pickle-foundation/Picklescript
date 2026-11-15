# PickleScript Standard Library

Source libraries for the standard library (`std.*`). Written in PickleScript,
with compiler intrinsics only where the runtime ABI (`pickle_*`) needs a thin
wrapper.

Seeds (see `docs/08-stdlib.md`, office `port/` tracker):

- `text/` — string/byte builder, UTF-8 helpers, format, identifier-case
  conversion (`casing.pkl`), line diffing (`diff.pkl`), word wrapping
  (`wrap.pkl`), `{name}` templates (`template.pkl`), regular expressions (`regex.pkl`), Unicode scalars, widths, and case mapping (`unicode.pkl`), cell-accurate text tables (`table.pkl`), slugs (`slug.pkl`), and word analysis (`words.pkl`); first seed
  `text/lexer.pkl` (the compiler lexer's scanner; validated at the time on the
  battery — see `tools/diff/port/`). The lexer seed is now legacy: the port's
  flat `pickle/compiler/{lexer,parser,resolve,check,emit}.pkl` slices took
  over lexing/parsing/checking, and this tree is where `std.*`/`runtime.*`
  seeds live (`text/{utf8,stringbuilder,format,lexer,ccm,casing,diff,wrap,template,regex,unicode,table,slug,words}`, `collections/*`,
  `encoding/{base64,csv,hex,url,toml,yaml,base32,xml}`, `math/{basic,random,statistics,interpolation,matrix,vector,fraction,prime,geometry,combinatorics,radix,complex}`, `fs`, `os`, `json`, `io`,
  `logging`, `process`, `test`, `time`, `thread`).
- `collections/` — `List`/`Map` wrappers plus `Set`, `Multiset`, `Deque`,
  `Vec`, `BitSet`, `LruCache`
- `fs/`, `os/`, `time/`, `test/` — shipped flat (`fs.pkl`, `os.pkl`, ...);
  `math/` has `basic.pkl`, `random.pkl`, `statistics.pkl`,
  `interpolation.pkl`, `matrix.pkl`, `vector.pkl`, `fraction.pkl`, `prime.pkl`, `geometry.pkl`, `combinatorics.pkl`, `radix.pkl`, and `complex.pkl`;
  `logging.pkl`
  ships flat (see the plan doc); `encoding/` has `base64`, `csv`, `hex`,
  `url`, `toml`, `yaml`, `base32`, and `xml`

Status (2026-09-26): the whole `stdlib/**/*_test.pkl` tree (50 files) is gated
by **GATE11** in `tools/battery_full.ps1` — the ported test driver must run
each file byte-identical (stdout + exit) to Rust `pickle test`.
The compiler registers builtins (`print`, `println`, `len`, `abs`, ...)
directly in the resolver, and the runtime ABI ships the foundation layer as
intrinsics: collection verbs (`List` push/pop/insert/remove/sort, `Map`
has/get/remove/keys/values/`[]`/entries), whole-file I/O
(`read_file`/`write_file`/`file_exists`/`delete`/`mkdir`/`list_dir`), the
buffered `Stream` layer, the `bytes()`/`str(List<byte>)` bridge, and the math
builtins (`min`/`max`/`clamp`/`range`/`abs`). `std.*` modules are thin
pickle wrappers over these plus genuinely new code, and every seed's `_test.pkl`
must keep GATE11 green.