;---------------------------------------------------------
;
;	LZ4 block 68k small depacker
;	Written by Arnaud Carré ( @leonard_coder )
;	https://github.com/arnaud-carre/lz4-68k
;
;	LZ4 technology by Yann Collet ( https://lz4.github.io/lz4/ )
;
;---------------------------------------------------------
;
; MODIFIED for execram (docs/format-spec.md's in-loop decompression
; flicker): a `move.w d0,(a5)` inserted after every byte copied in
; `.litcopy`/`.copy`, so a long-running decompression keeps writing
; changing data to whichever hardware color register `a5` was loaded
; with by this file's own stub_small_flash.s wrapper (COLOR17 by
; default, or COLOR00 with --killtwitch). `a5` is unused anywhere in
; the original file (confirmed by direct inspection), so this is safe
; without disturbing any of its register conventions. See
; stub_small_flash.s's own header comment for where `a5` is set up.

; Smallest version: depacker is only 72 bytes
;
; input: a0.l : packed buffer
;		 a1.l : output buffer
;		 d0.l : LZ4 packed block size (in bytes)
;
; output: none
;

lz4_depack:
			lea		0(a0,d0.l),a4	; packed buffer end
			moveq	#0,d0
			moveq	#0,d2
			moveq	#15,d4

.tokenLoop:	move.b	(a0)+,d0
			move.l	d0,d1
			lsr.b	#4,d1
			beq.s	.lenOffset

			bsr.s	.readLen

.litcopy:	move.b	(a0)+,(a1)+
			move.w	d0,(a5)		; flicker: keep the hardware color register changing
			subq.l	#1,d1			; block could be > 64KiB
			bne.s	.litcopy

			; end test is always done just after literals
			cmpa.l	a0,a4
			beq.s	.readEnd

			and.b	d4,d0

.lenOffset:	move.b	(a0)+,d2	; read 16bits offset, little endian, unaligned
			move.b	(a0)+,-(a7)
			move.w	(a7)+,d1
			move.b	d2,d1
			movea.l	a1,a3
			sub.l	d1,a3		; d1 bits 31..16 are always 0 here

			move.w	d0,d1

			bsr.s	.readLen

			addq.l	#4,d1
.copy:		move.b	(a3)+,(a1)+
			move.w	d0,(a5)		; flicker: keep the hardware color register changing
			subq.l	#1,d1
			bne.s	.copy
			bra.s	.tokenLoop

.readLen:	cmp.b	d1,d4
			bne.s	.readEnd
.readLoop:	move.b	(a0)+,d2
			add.l	d2,d1				; final len could be > 64KiB
			not.b	d2
			beq.s	.readLoop
.readEnd:	rts

