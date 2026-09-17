; "lz4normal" backend depacker stub, flash-instrumented variant
; (docs/format-spec.md's in-loop decompression flicker): identical to
; stub_normal.s except for loading a5 with the target hardware color
; register address (from FLAG_KILLTWITCH, read via a2 - still the real
; header pointer here, untouched anywhere in lz4_normal_flash.asm -
; confirmed by direct inspection) before calling lz4_depack, and
; lz4_normal_flash.asm instead of lz4_normal.asm.

	include	"../common/runtime.i"

Depack:
	btst	#4,HDR_FLAGS(a2)	; FLAG_KILLTWITCH
	beq.s	.color17
	lea	$dff180,a5		; COLOR00 (border/background)
	bra.s	.gotaddr
.color17:
	lea	$dff1a2,a5		; COLOR17 (mouse pointer sprite's own middle color) - default
.gotaddr:
	movem.l	d2-d7/a2-a6,-(a7)	; lz4_depack treats several of these as scratch - see README.md
	bsr.s	lz4_depack		; measured 8 bytes away - fits a short branch
	movem.l	(a7)+,d2-d7/a2-a6
	rts

	include	"lz4_normal_flash.asm"

	even
StubEnd:
