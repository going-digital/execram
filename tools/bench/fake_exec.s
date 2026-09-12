; Minimal fake Exec AllocMem/FreeMem, for tools/bench only (see that
; directory's README's "Known limitations", now resolved by this
; file). Not a real Exec - just enough to satisfy
; stubs/inflate/stub.s's own AllocMem/FreeMem calls when this harness
; jumps straight into Depack: with no real AmigaDOS environment around
; it at all (no library base, no other library, nothing at any other
; negative offset from ExecBase).
;
; tools/bench/main.zig places this binary so FreeMem's entry point
; (this file's very first byte) sits at ExecBase-210 and AllocMem's at
; ExecBase-198 - stubs/common/header.i's real EXEC_FreeMem/EXEC_AllocMem
; LVO constants. The 12-byte gap between the two entry points below is
; not a free choice: it's the actual difference between those two real
; Exec LVO numbers, so FreeMem is padded out to exactly 12 bytes rather
; than left at its own natural 2-byte length - main.zig computes
; ExecBase from wherever this binary is loaded, so the two routines
; only need to stay exactly 12 bytes apart, not at any particular
; absolute address.
;
; Correctness scope: this harness only ever drives one isolated
; Depack: call per run. Every stub that calls AllocMem at all (only
; inflate/zultra, sharing one stub) does so exactly once, for its own
; scratch buffer, freed just before Depack returns - never two
; overlapping live allocations. A real allocator (tracking a moving
; bump pointer, actually honoring FreeMem) isn't needed for that:
; AllocMem always hands back the same fixed scratch address (supplied
; by main.zig, which also keeps that whole region reserved and never
; places the stub/payload/output/stack there), and FreeMem is a no-op.

	include	"scratch_addr.i"	; FAKE_EXEC_SCRATCH_BASE - shared with main.zig, see that file

FreeMem:
	rts
	dc.b	0,0,0,0,0,0,0,0,0,0	; pad to exactly 12 bytes (AllocMem's fixed offset)

AllocMem:
	; In:  D0 = size, D1 = flags - both ignored (see module doc above).
	; Out: D0 = scratch pointer.
	move.l	#FAKE_EXEC_SCRATCH_BASE,d0
	rts
