; Shared v0 runtime skeleton (docs/format-spec.md §8), included by each
; backend's stub.s right before that backend defines `Depack`. Position-
; independent (PC-relative only) - no HUNK_RELOC32 needed for the
; assembled stub itself.
;
; The includer must define:
;
;   Depack:
;     In:  A0 = compressed payload pointer
;          A1 = output buffer pointer (must write exactly
;               code_data_size + reloc_stream_size bytes here)
;          D0 = compressed_size (informational; a self-terminating
;               backend format may ignore it)
;     Preserves D2-D7/A2-A6 - matches ShrinklerDecompress.S's own
;     convention (docs/LICENSES.md §1b), so a Shrinkler-derived backend
;     can plug into this skeleton with minimal glue. Free to clobber
;     D0/D1/A0/A1.

	include	"header.i"

EXEC_AllocMem	=	-198
EXEC_FreeMem	=	-210
MEMF_CHIP	=	2
MEMF_CLEAR	=	$10000

Start:
	lea	StubEnd(pc),a2		; a2 = header base, preserved throughout

	cmp.l	#MAGIC,HDR_MAGIC(a2)
	bne.w	Fail
	cmp.b	#VERSION_MAJOR_V0,HDR_VERSION_MAJOR(a2)
	bne.w	Fail

	move.l	4.w,a6			; ExecBase

	; scratch = AllocMem(code_data_size + reloc_stream_size, MEMF_ANY)
	move.l	HDR_CODE_DATA_SIZE(a2),d0
	add.l	HDR_RELOC_STREAM_SIZE(a2),d0
	moveq	#0,d1			; MEMF_ANY
	jsr	EXEC_AllocMem(a6)
	move.l	d0,a3			; a3 = scratch base, preserved
	tst.l	d0
	beq.w	Fail

	; Depack(compressed payload -> scratch)
	moveq	#0,d1
	move.w	HDR_HEADER_SIZE(a2),d1
	lea	0(a2,d1.l),a0		; a0 = compressed payload
	move.l	a3,a1			; a1 = output = scratch
	move.l	HDR_COMPRESSED_SIZE(a2),d0
	bsr.w	Depack

	; final = AllocMem(code_data_size + bss_size, MEMF_CLEAR [| MEMF_CHIP])
	; MEMF_CLEAR zeros the whole block, so the BSS tail needs no
	; explicit clearing loop (docs/format-spec.md §8 step 4).
	move.l	HDR_CODE_DATA_SIZE(a2),d0
	add.l	HDR_BSS_SIZE(a2),d0
	move.l	#MEMF_CLEAR,d1
	btst	#0,HDR_FLAGS(a2)	; FLAG_MEM_CHIP
	beq.s	.notchip
	or.l	#MEMF_CHIP,d1
.notchip:
	jsr	EXEC_AllocMem(a6)
	move.l	d0,a4			; a4 = final base
	tst.l	d0
	beq.w	Fail

	bsr.w	CopyCodeData
	btst	#1,HDR_FLAGS(a2)	; FLAG_HAS_RELOCS
	beq.s	.norelocs
	bsr.w	RelocFixup
.norelocs:

	; FreeMem(scratch, code_data_size + reloc_stream_size) - same size
	; expression as the AllocMem call that produced it; Exec's allocator
	; requires the exact original size back.
	move.l	HDR_CODE_DATA_SIZE(a2),d0
	add.l	HDR_RELOC_STREAM_SIZE(a2),d0
	move.l	a3,a1
	jsr	EXEC_FreeMem(a6)

	jmp	(a4)

Fail:
	; docs/format-spec.md §8: no recovery behavior defined for v0 (only
	; one major version exists so far, and there's nothing sensible to
	; do about a failed AllocMem here) - hang rather than run off into
	; garbage.
	bra.s	Fail

; Copies the first code_data_size bytes of scratch(a3) to final(a4).
; Every hunk's size is stored in longwords in the source file
; (src/hunk.zig), so code_data_size - a sum of hunk sizes - is always a
; multiple of 4: no byte-remainder handling needed here (contrast
; Depack, whose input length has no such guarantee).
CopyCodeData:
	move.l	HDR_CODE_DATA_SIZE(a2),d0
	lsr.l	#2,d0
	move.l	a3,a0
	move.l	a4,a1
.loop:
	tst.l	d0
	beq.s	.done
	move.l	(a0)+,(a1)+
	subq.l	#1,d0
	bra.s	.loop
.done:
	rts

; Walks the reloc stream (docs/format-spec.md §7) at
; scratch+code_data_size, patching each recorded site in final(a4) by
; adding final's own runtime base address to whatever's already there
; (flatten.zig already folded each site's target-hunk offset into that
; stored value - see src/flatten.zig's module doc).
RelocFixup:
	move.l	HDR_CODE_DATA_SIZE(a2),d0
	lea	0(a3,d0.l),a5		; a5 = reloc-stream read pointer
	moveq	#0,d6			; d6 = running site offset ("prev")
.next:
	moveq	#0,d1
	move.b	(a5)+,d1
	cmp.b	#RELOC_STREAM_END,d1
	beq.s	.done
	cmp.b	#RELOC_STREAM_ESCAPE,d1
	bne.s	.havehalf
	move.l	(a5)+,d1
.havehalf:
	lsl.l	#1,d1			; delta = half_delta * 2
	add.l	d1,d6
	move.l	(a4,d6.l),d2
	add.l	a4,d2
	move.l	d2,(a4,d6.l)
	bra.s	.next
.done:
	rts

; NOTE: StubEnd is NOT defined here. runtime.i is `include`d before each
; backend's own Depack code, so a label placed here would land at the
; start of Depack, not at the true end of the assembled stub - that was
; a real bug, caught by tests/uae/e2e's boot test (see that script's
; history/commit message). Each backend's stub.s must define
; `even` / `StubEnd:` itself, after its own Depack routine.
