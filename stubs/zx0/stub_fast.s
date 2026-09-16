; "zx0fast"/"salvadorfast" backend depacker stub: real ZX0 decompression
; via Chris Hodges (Platon42)'s fork of unzx0_68000 (unzx0_68000_fast.s
; in this directory - see README.md for provenance/license and exactly
; how it compares to the "zx0"/"salvador" backends' own stub).
;
; Unlike unzx0_68000.s, this version's own header says it "trashes:
; d0-d2/a2" - it doesn't preserve D2/A2 itself, so (like the lz4
; backends' stubs - stubs/lz4/README.md) it needs a
; movem.l/bsr.w/movem.l wrapper rather than a bare `include`.

	include	"../common/runtime.i"

Depack:
	movem.l	d2/a2,-(sp)
	bsr.w	zx0_decompress
	movem.l	(sp)+,d2/a2
	rts

	include	"unzx0_68000_fast.s"

	even
StubEnd:
