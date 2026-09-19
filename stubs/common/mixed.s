; v1 grouped-memory dispatcher. Hunk order: resident 0, scratch, other
; residents. Scratch contains this dispatcher, a 44-byte header, 52-byte
; descriptors, one ordinary depacker stub and any disjoint payloads.
; Each descriptor starts with a normal 36-byte ExCr header (A2 for flash
; wrappers), then runtime base, input offset, overlap destination offset,
; and allocation size. All bases are resolved before any relocation.
	include "header.i"
DESC_SIZE = 52
DESC_BASE = 36
DESC_INPUT = 40
DESC_DEST = 44
Start:
	lea MixedHeader(pc),a5
	move.l a4,d5		; original entry, preserved by every Depack
	lea 44(a5),a2
	move.l 36(a5),d7
	move.l a4,a0
	move.l a4,DESC_BASE(a2)
	; Skip scratch when following the first resident's link.
	move.l -4(a0),d0
	lsl.l #2,d0
	move.l d0,a0
	addq.l #4,a0
	subq.l #1,d7
	beq.s .mapped
.map:
	move.l -4(a0),d0
	lsl.l #2,d0
	move.l d0,a0
	addq.l #4,a0
	lea DESC_SIZE(a2),a2
	move.l a0,DESC_BASE(a2)
	subq.l #1,d7
	bne.s .map
.mapped:
	lea Start(pc),a3
	adda.l 40(a5),a3		; selected Depack entry (flash or plain)
	lea 44(a5),a2
	move.l 36(a5),d7
.group:
	move.l DESC_BASE(a2),a4
	btst #3,HDR_FLAGS(a2)
	beq.s .disjoint
	move.l a4,a0
	adda.l DESC_INPUT(a2),a0
	move.l a4,a1
	adda.l DESC_DEST(a2),a1
	move.l HDR_COMPRESSED_SIZE(a2),d0
	addq.l #3,d0
	and.l #-4,d0
	adda.l d0,a0
	adda.l d0,a1
	lsr.l #2,d0
.copy:
	move.l -(a0),-(a1)
	subq.l #1,d0
	bne.s .copy
	move.l a4,a0
	adda.l DESC_DEST(a2),a0
	bra.s .decode
.disjoint:
	lea Start(pc),a0
	adda.l DESC_INPUT(a2),a0
.decode:
	move.l a4,a1
	move.l HDR_COMPRESSED_SIZE(a2),d0
	; Legacy wrappers set flash registers/parity before their own saves.
	; Preserve dispatcher state outside those wrappers as well.
	movem.l d2-d7/a2-a6,-(sp)
	jsr (a3)
	movem.l (sp)+,d2-d7/a2-a6

	; Relocation: target group byte, half-delta (or FF + BE32).
	move.l a4,a0
	adda.l HDR_CODE_DATA_SIZE(a2),a0
	moveq #0,d6
.reloc:
	moveq #0,d2
	move.b (a0)+,d2
	cmp.b #$fe,d2
	beq.s .clear
	mulu #DESC_SIZE,d2
	lea 44(a5),a1
	adda.l d2,a1
	move.l DESC_BASE(a1),d2
	moveq #0,d1
	move.b (a0)+,d1
	cmp.b #$ff,d1
	bne.s .delta
	moveq #0,d1
	move.b (a0)+,d1
	lsl.l #8,d1
	move.b (a0)+,d1
	lsl.l #8,d1
	move.b (a0)+,d1
	lsl.l #8,d1
	move.b (a0)+,d1
.delta:
	add.l d1,d1
	add.l d1,d6
	add.l d2,0(a4,d6.l)
	bra.s .reloc
.clear:
	move.l a4,a0
	adda.l HDR_CODE_DATA_SIZE(a2),a0
	move.l HDR_BSS_SIZE(a2),d0
	lsr.l #2,d0
	beq.s .next
.zero:
	clr.l (a0)+
	subq.l #1,d0
	bne.s .zero
.next:
	lea DESC_SIZE(a2),a2
	subq.l #1,d7
	bne.w .group

	; Remove only scratch, retaining the other residents for UnLoadSeg.
	move.l d5,a4
	lea Start(pc),a3
	move.l -4(a3),-4(a4)
	move.l -8(a3),d0
	lea -8(a3),a1
	move.l 4.w,a6
	jsr -210(a6)
	jmp (a4)
	even
MixedHeader:
