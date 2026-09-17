; "inflate" backend depacker stub, flash-instrumented variant
; (docs/format-spec.md's in-loop decompression flicker): identical to
; stub.s except for caching HDR_FLAGS into D7 (read via A2 - still the
; real header pointer here, since the initial movem.l only *pushes* a
; copy of it onto the stack, it doesn't clear the live register - before
; A2 gets overwritten with the AllocMem scratch pointer a few lines
; down), and inflate_core_flash.s instead of inflate_core.s.
;
; D7's own cached value must be set *after* the initial
; `movem.l d2-d7/a2-a6,-(sp)` below, not before: that instruction saves
; whatever the CALLER's own D7 was (which this routine's own contract -
; "Preserves D2-D7/A2-A6" - must hand back unchanged once Depack
; returns), and the final `movem.l (sp)+,...` at the bottom restores
; that saved value regardless of what D7 held in between - so using D7
; as a scratch/carry channel here is safe exactly because the
; save/restore already brackets it.
;
; D7 is otherwise untouched anywhere in inflate_core_flash.s except
; inside `build_code`'s own self-contained save/restore (confirmed by
; direct inspection - see that file's own header comment), so this
; cached value survives unchanged all the way to where
; inflate_core_flash.s itself needs it (right after both `build_code`
; calls, before `decode_loop:` starts).

	include	"../common/runtime.i"
	include	"inflate_core_flash.s"

INFLATE_STORAGE_SIZE	=	2928

Depack:
	movem.l	d2-d7/a2-a6,-(sp)

	moveq	#0,d7
	move.b	HDR_FLAGS(a2),d7	; cached for inflate_core_flash.s's own use - see this file's own header comment

	move.l	a1,a4			; a4 = output (inflate.S's convention)
	move.l	a0,a5			; a5 = input

	move.l	4.w,a6			; ExecBase
	move.l	#INFLATE_STORAGE_SIZE,d0
	moveq	#0,d1			; MEMF_ANY
	jsr	EXEC_AllocMem(a6)
	move.l	d0,a2			; a2 = scratch block base (reused; our
					; caller's a2 is safe on the stack)
	tst.l	d0
	beq.w	Fail			; defined in runtime.i

	add.l	#INFLATE_STORAGE_SIZE,d0
	move.l	d0,a6			; a6 = *end* of scratch (OPT_STORAGE_OFFSTACK)

	bsr.s	inflate			; d7 still holds our cached flags byte throughout - see this file's own header comment

	move.l	4.w,a6			; ExecBase again - inflate's own top-level
					; entry deliberately doesn't preserve A6
					; (its scratch-end-pointer argument), so
					; a6 still holds that, not this
	move.l	#INFLATE_STORAGE_SIZE,d0
	move.l	a2,a1
	jsr	EXEC_FreeMem(a6)

	movem.l	(sp)+,d2-d7/a2-a6	; restores the CALLER's own original d2-d7/a2-a6, discarding our own d7 use
	rts

	even
StubEnd:
