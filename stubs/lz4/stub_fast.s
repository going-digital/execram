; "lz4fast" backend depacker stub: LZ4 decompression via the fastest
; (068000-friendly, no icache assumed) of arnaud-carre/lz4-68k's three
; depacker variants (see README.md in this directory for provenance/
; license/size-vs-speed trade-off).

	include	"../common/runtime.i"

Depack:
	movem.l	d2-d7/a2-a6,-(a7)	; lz4_depack treats several of these as scratch - see README.md
	bsr.s	lz4_depack		; measured 8 bytes away - fits a short branch
	movem.l	(a7)+,d2-d7/a2-a6
	rts

	include	"lz4_fastest.asm"

	even
StubEnd:
