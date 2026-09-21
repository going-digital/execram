; "store" backend's Depack: routine, flash-instrumented variant
; (docs/format-spec.md's in-loop decompression flicker) - identical to
; depack_core.s except for the register-indirect COLOR17/COLOR00 poke
; inside the hot copy loop. A separate file, not a shared/conditional
; one, matching this project's own established convention for near-
; identical stub variants (zx0 vs zx0fast, lz4small/normal/fast).
;
; Register setup, once, before the loop: A2 (still the header pointer
; here - Depack: is called directly via runtime.i's `bsr.w Depack` with
; A2 intact) is read for FLAG_KILLTWITCH, then A3 (confirmed unused
; anywhere in the plain depack_core.s, so no save/restore needed) is
; loaded with the target hardware address. A2 itself is NEVER touched:
; Depack's own contract requires preserving A2-A6 (runtime.i re-reads
; HDR_FLAGS/HDR_CODE_DATA_SIZE/HDR_BSS_SIZE via A2 again after this
; routine returns, for RelocFixup/the BSS-clear step), so the target
; address needs its own, genuinely free register rather than reusing A2
; directly.
;
; In:  A0 = input, A1 = output, D0 = length in bytes.
; Preserves D2-D7/A2-A6 per runtime.i's contract (only D0/D1/A0/A1/A3 are
; touched - A3 is scratch here, not part of that contract, since nothing
; outside this routine ever needs its value).
Depack:
	btst	#4,HDR_FLAGS(a2)	; FLAG_KILLTWITCH
	beq.s	.color17
	lea	$dff180,a3		; COLOR00 (border/background)
	bra.s	.gotaddr
.color17:
	lea	$dff1a2,a3		; COLOR17 (mouse pointer sprite's own middle color) - default
.gotaddr:

	move.l	d0,d1
	lsr.l	#2,d0
	beq.s	.rembytes
.longs:
	move.l	(a0)+,(a1)+
	move.w	d0,(a3)			; flicker: whatever's left in the loop counter, changes every pass
	subq.l	#1,d0
	bne.s	.longs
.rembytes:
	moveq	#3,d0
	and.l	d0,d1
	beq.s	.done
.rbloop:
	move.b	(a0)+,(a1)+
	subq.l	#1,d1
	bne.s	.rbloop
.done:
	rts
