; "inflate" backend depacker stub: real DEFLATE decompression via a
; vendored/adapted Keir Fraser inflate.S (see inflate_core.s and
; README.md for why this whole stub is std-syntax, unlike every other
; stub in this project).

	.include	"runtime_std.i"
	.include	"inflate_core.s"

; inflate.S's OPT_STORAGE_OFFSTACK convention: A6 must point at the
; *end* of this many bytes of scratch memory. 2928 is upstream's own
; documented figure for OPT_TABLE_LOOKUP=1 (kept at its default, on).
.equ INFLATE_STORAGE_SIZE,2928

; In:  A0 = compressed (DEFLATE) input, A1 = output.
;      D0 = compressed_size - unused: DEFLATE streams are
;      self-terminating, inflate.S decodes until the final block's
;      end-of-block marker regardless.
; Preserves D2-D7/A2-A6 per runtime_std.i's contract by saving them
; up front and restoring before returning - freely reused as scratch
; (including for ExecBase and inflate.S's own A4/A5/A6 arguments) in
; between. Must be D2-D7, not just A2-A6: inflate's own top-level entry
; (inflate_core.s) only saves/restores D0-D6/A0-A5 around itself
; (deliberately excluding A6, its scratch-end-pointer argument, and
; D7, which it makes no promise about at all) - relying on that alone
; would leave D7 not actually guaranteed preserved on return, contrary
; to this comment's own claim. Save/restore the full contract here
; instead of trusting the vendored decoder's internals to happen to
; match it.
Depack:
	movem.l	d2-d7/a2-a6,-(sp)

	move.l	a1,a4			; a4 = output (inflate.S's convention)
	move.l	a0,a5			; a5 = input

	move.l	4.w,a6			; ExecBase
	move.l	#INFLATE_STORAGE_SIZE,d0
	moveq	#0,d1			; MEMF_ANY
	jsr	EXEC_AllocMem(a6)
	move.l	d0,a2			; a2 = scratch block base (reused; our
					; caller's a2 is safe on the stack)
	tst.l	d0
	beq.w	Fail			; defined in runtime_std.i

	add.l	#INFLATE_STORAGE_SIZE,d0
	move.l	d0,a6			; a6 = *end* of scratch (OPT_STORAGE_OFFSTACK)

	bsr.s	inflate			; measured 120 bytes away - fits a short branch

	move.l	4.w,a6			; ExecBase again - inflate's own top-level
					; entry deliberately doesn't preserve A6
					; (its scratch-end-pointer argument), so
					; a6 still holds that, not this
	move.l	#INFLATE_STORAGE_SIZE,d0
	move.l	a2,a1
	jsr	EXEC_FreeMem(a6)

	movem.l	(sp)+,d2-d7/a2-a6
	rts

	.even
StubEnd:
