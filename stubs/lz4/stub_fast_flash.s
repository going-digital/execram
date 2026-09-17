; "lz4fast" backend depacker stub, flash-instrumented variant
; (docs/format-spec.md's in-loop decompression flicker): identical to
; stub_fast.s except for loading a5 with the target hardware color
; register address (from FLAG_KILLTWITCH, read via a2 - still the real
; header pointer here, not yet touched - lz4_depack itself later
; repurposes a2 as scratch, but only after this wrapper's own movem.l
; has already saved the caller's real a2 to the stack) before calling
; lz4_depack, and lz4_fastest_flash.asm instead of lz4_fastest.asm.

	include	"../common/runtime.i"

Depack:
	btst	#4,HDR_FLAGS(a2)	; FLAG_KILLTWITCH
	beq.s	.color19
	lea	$dff180,a5		; COLOR00 (border/background)
	bra.s	.gotaddr
.color19:
	lea	$dff1a6,a5		; COLOR19 (mouse pointer sprite's own middle color) - default
.gotaddr:
	movem.l	d2-d7/a2-a6,-(a7)	; lz4_depack treats several of these as scratch - see README.md
	bsr.s	lz4_depack
	movem.l	(a7)+,d2-d7/a2-a6
	rts

	include	"lz4_fastest_flash.asm"

	even
StubEnd:
