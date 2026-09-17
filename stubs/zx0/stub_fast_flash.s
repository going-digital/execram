; "zx0fast"/"salvadorfast" backend depacker stub, flash-instrumented
; variant (docs/format-spec.md's in-loop decompression flicker):
; identical to stub_fast.s except for reading FLAG_KILLTWITCH and loading
; A3 with the target hardware address before the `bsr.s zx0_decompress`
; call - A2 is still the real header pointer at this point (the
; `movem.l d2/a2,-(sp)` right after hasn't run yet), which
; unzx0_68000_fast_flash.s itself needs (unlike unzx0_68000.s, that file
; doesn't preserve A2 on its own, so this is the only point where reading
; the header via A2 is safe) - and unzx0_68000_fast_flash.s instead of
; unzx0_68000_fast.s.

	include	"../common/runtime.i"

Depack:
	btst	#4,HDR_FLAGS(a2)	; FLAG_KILLTWITCH
	beq.s	.color19
	lea	$dff180,a3		; COLOR00 (border/background)
	bra.s	.gotaddr
.color19:
	lea	$dff1a6,a3		; COLOR19 (mouse pointer sprite's own middle color) - default
.gotaddr:
	movem.l	d2/a2,-(sp)
	bsr.s	zx0_decompress		; measured well within short-branch range
	movem.l	(sp)+,d2/a2
	rts

	include	"unzx0_68000_fast_flash.s"

	even
StubEnd:
