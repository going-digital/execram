; "lz4small" backend depacker stub: LZ4 decompression via the smallest
; of arnaud-carre/lz4-68k's three depacker variants (see README.md in
; this directory for provenance/license/size-vs-speed trade-off).

	include	"../common/runtime.i"

Depack:
	movem.l	d2-d7/a2-a6,-(a7)	; lz4_depack treats several of these as scratch - see README.md
	bsr.w	lz4_depack
	movem.l	(a7)+,d2-d7/a2-a6
	rts

	include	"lz4_smallest.asm"

	even
StubEnd:
