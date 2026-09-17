; "store" backend depacker stub: no compression at all - the payload
; already IS the code_data+reloc_stream bytes verbatim. Exists to prove
; the container format's v0 runtime algorithm (docs/format-spec.md §8)
; works end to end before any real compression backend does (M1's
; deliverable), and as the baseline `--backend=store`/`--backend=auto`
; always has available.

	include	"runtime.i"	; resolved via vasm's -I stubs/common (build.zig) - serves both the default and overlap layouts (docs/format-spec.md §8b), branching on FLAG_OVERLAP
	include	"depack_core.s"	; Depack: - split out on its own for clarity, not shared with a second stub source

	even
StubEnd:
