; "shrinkler" backend depacker stub, flash-instrumented variant
; (docs/format-spec.md's in-loop decompression flicker): identical to
; stub.s except for reading FLAG_KILLTWITCH and loading A3 with the
; target hardware address before `suba.l a2,a2` zeroes A2 (A2 is still
; the real header pointer up to that point - see stub.s's own extensive
; comment on why A2 must be saved/restored around this call at all: the
; same reasoning means it must be read for FLAG_KILLTWITCH *before* it's
; zeroed here, not after), and ShrinklerDecompress_flash.s instead of
; ShrinklerDecompress.s.

	include	"../common/runtime.i"

Depack:
	move.l	a2,-(sp)		; save the real header base
	btst	#4,HDR_FLAGS(a2)	; FLAG_KILLTWITCH (a2 still valid here)
	beq.s	.color19
	lea	$dff180,a3		; COLOR00 (border/background)
	bra.s	.gotaddr
.color19:
	lea	$dff1a6,a3		; COLOR19 (mouse pointer sprite's own middle color) - default
.gotaddr:
	suba.l	a2,a2			; no progress callback
	moveq	#1,d7			; parity context on (Shrinkler's own --data default)
	bsr.s	ShrinklerDecompress	; measured well within short-branch range
	move.l	(sp)+,a2		; restore it for runtime.i's own later use
	rts

	include	"ShrinklerDecompress_flash.s"

	even
StubEnd:
