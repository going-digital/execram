;---------------------------------------------------------
;
;	LZ4 block 68k depacker
;	Written by Arnaud Carré ( @leonard_coder )
;	https://github.com/arnaud-carre/lz4-68k
;
;	LZ4 technology by Yann Collet ( https://lz4.github.io/lz4/ )
;
;---------------------------------------------------------
;
; MODIFIED for execram (docs/format-spec.md's in-loop decompression
; flicker): a `move.w d0,(a5)` inserted after every byte copied in the
; counted `.litcopy`/`.copy` loops (runs of 15+ literals/match bytes
; within a single token), so a long-running decompression keeps writing
; changing data to whichever hardware color register `a5` was loaded
; with by this file's own stub_normal_flash.s wrapper (COLOR17 by
; default, or COLOR00 with --killtwitch). The hand-unrolled short-run
; paths (`.small`/`.litcopys`, for runs under 15 bytes - the common
; case) are left untouched, matching lz4fast's own accepted
; per-token-not-per-byte exception: instrumenting a fully-unrolled
; jump table would need a poke duplicated at every one of its 15 copy
; sites, for no benefit over the already-instrumented counted loop that
; every token exceeding it still passes through. `a5` is unused
; anywhere in the original file (confirmed by direct inspection), so
; this is safe without disturbing any of its register conventions. See
; stub_normal_flash.s's own header comment for where `a5` is set up.

; Normal version: 180 bytes ( 1.53 times faster than lz4_smallest.asm )
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
			moveq	#0,d3
			moveq	#15,d4
			bra.s	.tokenLoop

.lenOffset:	move.b	(a0)+,d1	; read 16bits offset, little endian, unaligned
			move.b	(a0)+,-(a7)
			move.w	(a7)+,d3
			move.b	d1,d3
			movea.l	a1,a3
			sub.l	d3,a3
			move.w	d0,d1
			cmp.b	d4,d1
			bne.s	.small

.readLen0:	move.b	(a0)+,d2
			add.l	d2,d1
			not.b	d2
			beq.s	.readLen0

			addq.l	#4,d1
.copy:		move.b	(a3)+,(a1)+
			move.w	d0,(a5)		; flicker: keep the hardware color register changing
			subq.l	#1,d1
			bne.s	.copy
			bra		.tokenLoop

.small:		add.w	d1,d1
			neg.w	d1
			jmp		.copys(pc,d1.w)
; MODIFIED for execram: use Motorola-syntax REPT/ENDR for upstream's
; repeat blocks. Expansion preserves instruction offsets and jump targets.
			REPT	15
			move.b	(a3)+,(a1)+
			ENDR
.copys:
			REPT	4
			move.b	(a3)+,(a1)+
			ENDR

.tokenLoop:	move.b	(a0)+,d0
			move.l	d0,d1
			lsr.b	#4,d1
			beq.s	.lenOffset
			and.w	d4,d0
			cmp.b	d4,d1
			beq.s	.readLen1

.litcopys:	add.w	d1,d1
			neg.w	d1
			jmp		.copys2(pc,d1.w)
; Same assembly-time repetition as .small above.
			REPT	15
			move.b	(a0)+,(a1)+
			ENDR
.copys2:
			cmpa.l	a0,a4
			bne		.lenOffset
			rts

.readLen1:	move.b	(a0)+,d2
			add.l	d2,d1
			not.b	d2
			beq.s	.readLen1

.litcopy:	move.b	(a0)+,(a1)+
			move.w	d0,(a5)		; flicker: keep the hardware color register changing
			subq.l	#1,d1
			bne.s	.litcopy

			; end test is always done just after literals
			cmpa.l	a0,a4
			bne		.lenOffset

.over:		rts						; end

