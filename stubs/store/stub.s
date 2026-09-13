; "store" backend depacker stub: no compression at all - the payload
; already IS the code_data+reloc_stream bytes verbatim. Exists to prove
; the container format's v0 runtime algorithm (docs/format-spec.md §8)
; works end to end before any real compression backend does (M1's
; deliverable), and as the baseline `--backend=store`/`--backend=auto`
; always has available.

	include	"runtime.i"	; resolved via vasm's -I stubs/common (build.zig)

; In:  A0 = input, A1 = output, D0 = length in bytes.
; Preserves D2-D7/A2-A6 per runtime.i's contract (trivially true here -
; this only touches D0/D1/A0/A1 anyway).
;
; D0 has no multiple-of-4 guarantee (unlike code_data_size alone, always
; a multiple of 4 since every hunk's own size is stored in longwords -
; see src/hunk.zig): it's code_data_size + reloc_stream_size, and
; reloc_stream bytes aren't longword-counted. Longword-copy the bulk,
; then finish any 0-3 remaining bytes individually.
Depack:
	move.l	d0,d1
	lsr.l	#2,d0
.longs:
	tst.l	d0
	beq.s	.rembytes
	move.l	(a0)+,(a1)+
	subq.l	#1,d0
	bra.s	.longs
.rembytes:
	and.l	#3,d1
	beq.s	.done
.rbloop:
	move.b	(a0)+,(a1)+
	subq.l	#1,d1
	bne.s	.rbloop
.done:
	rts

	even
StubEnd:
