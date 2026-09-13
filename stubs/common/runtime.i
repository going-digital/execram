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

; FLAG_FLASH support (docs/format-spec.md §5): a purely cosmetic,
; optional "something is happening" indicator for slow backends on
; real hardware - decompression of a large file under a backend like
; shrinkler can take tens of seconds of real 68000 time (see
; tools/bench's own measurements), with nothing else on screen to show
; the machine hasn't hung. COLOR00 is the background/border colour
; register - a real, fixed hardware address, not a relocatable program
; one, same category as the other absolute addresses this file already
; uses (EXEC_AllocMem/EXEC_FreeMem via a6, ExecBase itself via 4.w).
CUSTOM_COLOR00	=	$dff180
FLASH_COLOR	=	$0f00		; bright red

Start:
	lea	StubEnd(pc),a2		; a2 = header base, preserved throughout

	cmp.l	#MAGIC,HDR_MAGIC(a2)
	bne.w	Fail
	cmp.b	#VERSION_MAJOR_V0,HDR_VERSION_MAJOR(a2)
	bne.w	Fail

	move.l	4.w,a6			; ExecBase

	; final = AllocMem(code_data_size + max(bss_size, reloc_stream_size), MEMF_CLEAR [| MEMF_CHIP])
	;
	; One allocation, not two: Depack decompresses DIRECTLY into this
	; buffer (no separate "scratch" AllocMem, no CopyCodeData, no
	; FreeMem) - the buffer just needs to be big enough for whichever
	; is larger, the real BSS tail the program needs at runtime, or
	; the reloc stream RelocFixup still has to read right after Depack
	; returns (both occupy the same trailing region, just at different
	; times - Depack/RelocFixup leave that region holding whatever's
	; left of the reloc stream, not zero, so it's explicitly re-cleared
	; below, right before jumping in, to satisfy the program's own BSS
	; convention).
	;
	; This isn't just fewer library calls: the ORIGINAL packed image
	; (this stub + header + compressed payload) is never freed - it's
	; the process's own code segment for its whole lifetime, not
	; memory we control - so the old two-allocation scheme needed the
	; original packed image AND a full scratch buffer AND a full final
	; buffer all resident at once, right after the second AllocMem and
	; before the first is freed. On a base 512KB Amiga that peak can
	; easily exceed total memory even when the packed file is much
	; smaller than the original - confirmed directly: a real 221KB
	; program packed with zultra needed a peak of ~564KB (144KB packed
	; + 216KB scratch + 218KB final) under the old scheme, comfortably
	; over 512KB on its own before Kickstart's own overhead - and only
	; ~354KB under this one.
	move.l	HDR_CODE_DATA_SIZE(a2),d0
	move.l	HDR_BSS_SIZE(a2),d1
	cmp.l	HDR_RELOC_STREAM_SIZE(a2),d1
	bcc.s	.tailok			; bss_size >= reloc_stream_size already
	move.l	HDR_RELOC_STREAM_SIZE(a2),d1
.tailok:
	add.l	d1,d0
	move.l	#MEMF_CLEAR,d1
	btst	#0,HDR_FLAGS(a2)	; FLAG_MEM_CHIP
	beq.s	.notchip
	or.l	#MEMF_CHIP,d1
.notchip:
	jsr	EXEC_AllocMem(a6)
	move.l	d0,a4			; a4 = final base (Depack's output too)
	tst.l	d0
	beq.w	Fail

	; Depack(compressed payload -> final)
	moveq	#0,d1
	move.w	HDR_HEADER_SIZE(a2),d1
	lea	0(a2,d1.l),a0		; a0 = compressed payload
	move.l	a4,a1			; a1 = output = final, directly
	move.l	HDR_COMPRESSED_SIZE(a2),d0

	btst	#2,HDR_FLAGS(a2)	; FLAG_FLASH
	beq.s	.noflashon
	move.w	#FLASH_COLOR,CUSTOM_COLOR00
.noflashon:
	bsr.w	Depack
	btst	#2,HDR_FLAGS(a2)	; FLAG_FLASH - re-tested, not cached:
	beq.s	.noflashoff		; Depack is free to clobber condition
	move.w	#0,CUSTOM_COLOR00	; codes along with D0/D1/A0/A1.
.noflashoff:

	btst	#1,HDR_FLAGS(a2)	; FLAG_HAS_RELOCS
	beq.s	.norelocs
	bsr.w	RelocFixup
.norelocs:

	; Clear BSS: this region of the buffer still holds whatever Depack/
	; RelocFixup last left there (the just-consumed reloc stream, when
	; there was one - shorter than bss_size whenever reloc_stream_size
	; < bss_size, so its tail is stale AllocMem-time zero but the head
	; is leftover reloc-stream bytes either way). The program's BSS must
	; be all-zero at entry, so clear it again here rather than relying
	; on AllocMem's own MEMF_CLEAR, which only zeroed this space
	; *before* Depack/RelocFixup wrote all over it. bss_size is always a
	; multiple of 4 - hunk sizes are stored in longwords, same guarantee
	; code_data_size has (see stubs/store/stub.s's own comment).
	move.l	HDR_CODE_DATA_SIZE(a2),d0
	lea	0(a4,d0.l),a0		; a0 = start of BSS within final
	move.l	HDR_BSS_SIZE(a2),d0
	lsr.l	#2,d0
	beq.s	.bssdone
.bssclear:
	clr.l	(a0)+
	subq.l	#1,d0
	bne.s	.bssclear
.bssdone:

	jmp	(a4)

Fail:
	; docs/format-spec.md §8: no recovery behavior defined for v0 (only
	; one major version exists so far, and there's nothing sensible to
	; do about a failed AllocMem here) - hang rather than run off into
	; garbage.
	bra.s	Fail

; Walks the reloc stream (docs/format-spec.md §7) at final+code_data_size
; (Depack wrote code_data ++ reloc_stream there directly - no separate
; scratch buffer to read it from anymore), patching each recorded site
; in final(a4) by adding final's own runtime base address to whatever's
; already there (flatten.zig already folded each site's target-hunk
; offset into that stored value - see src/flatten.zig's module doc).
RelocFixup:
	move.l	HDR_CODE_DATA_SIZE(a2),d0
	lea	0(a4,d0.l),a5		; a5 = reloc-stream read pointer
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
