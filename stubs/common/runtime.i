; Shared v0 runtime skeleton (docs/format-spec.md §8), included by each
; backend's stub.s right before that backend defines `Depack`. Position-
; independent (PC-relative only) - no HUNK_RELOC32 needed for the
; assembled stub itself.
;
; This is hunk 1's own code - reached via a jump from hunk 0's tiny,
; backend-agnostic trampoline (stubs/common/trampoline.s), not
; AmigaDOS's own LoadSeg entry point (that's hunk 0). The trampoline
; hands off A4 = hunk 0's own base address (Depack's output target, and
; the real program's own entry point once decompression finishes) in a
; register and jumps here; nothing else is handed off, since everything
; else this file needs (its own header, its own size for freeing
; itself once done) it locates independently via its own PC-relative
; addressing, matching this file's existing position-independent style.
;
; ABI this depends on for finding its own size and freeing itself
; (confirmed empirically under real FS-UAE across Kickstart v1.3
; r34.005/v2.05 r37.350/v3.1 r40.063 - see the commit that introduced
; this design for the probe and raw results): every hunk AmigaDOS's
; LoadSeg loads carries an 8-byte header immediately before its own
; "public" data - that hunk's own total AllocMem'd size in bytes
; (already including this 8-byte header, exactly what FreeMem needs)
; at data_start-8, and a BCPL-shifted pointer to the next hunk's own
; "+4" field (0 if none) at data_start-4.
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

; EXEC_AllocMem is no longer used by Start: itself (see below) - kept
; here since it's still a real Exec LVO a backend's own Depack may need
; for its own internal scratch space (the inflate stub's decode window,
; e.g. - stubs/inflate/stub.s), same as EXEC_FreeMem.
EXEC_AllocMem	=	-198
EXEC_FreeMem	=	-210

; FLAG_FLASH support (docs/format-spec.md §5): a purely cosmetic,
; optional "something is happening" indicator for slow backends on
; real hardware - decompression of a large file under a backend like
; shrinkler can take tens of seconds of real 68000 time (see
; tools/bench's own measurements), with nothing else on screen to show
; the machine hasn't hung. COLOR00 is the background/border colour
; register - a real, fixed hardware address, not a relocatable program
; one, same category as the other absolute addresses this file already
; uses (EXEC_FreeMem via a6, ExecBase itself via 4.w).
CUSTOM_COLOR00	=	$dff180
FLASH_COLOR	=	$0f00		; bright red

Start:
	lea	StubEnd(pc),a2		; a2 = header base, preserved throughout

	cmp.l	#MAGIC,HDR_MAGIC(a2)
	bne.w	Fail
	cmp.b	#VERSION_MAJOR_V0,HDR_VERSION_MAJOR(a2)
	bne.w	Fail

	move.l	4.w,a6			; ExecBase

	; No allocation at all: A4 already holds hunk 0's own base (Depack's
	; output target), handed in by the trampoline. Hunk 0 is AmigaDOS's
	; own LoadSeg allocation - container.zig (main.zig's hunk0Size)
	; declares it at code_data_size + max(bss_size, reloc_stream_size),
	; not just code_data_size + bss_size: Depack writes reloc_stream_size
	; bytes into the same trailing region BSS ends up in (see the
	; BSS-reclear step's own comment below), so hunk 0 must be sized for
	; whichever is larger or Depack overflows it into hunk 1 - a real
	; bug once, only exposed by a real program whose reloc_stream_size
	; happened to exceed its bss_size (most don't). The right memory
	; type is set up front too, so there is nothing left for this code to
	; allocate. The rest of hunk 0's allocation is uninitialized until
	; Depack fills it below; nothing here depends on it starting zeroed
	; (the BSS re-clear step further down makes no assumption about
	; prior state either - see its own comment).

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
	; < bss_size, so its tail is stale (uninitialized, now that there's
	; no AllocMem MEMF_CLEAR at all) but the head is leftover
	; reloc-stream bytes either way). The program's BSS must be all-zero
	; at entry, so clear it here unconditionally - this step makes no
	; assumption about what was here before it runs. bss_size is always
	; a multiple of 4 - hunk sizes are stored in longwords, same
	; guarantee code_data_size has (see stubs/store/stub.s's own
	; comment).
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

	; Detach hunk 1 (this hunk) from hunk 0's own chain-pointer field so
	; AmigaDOS's own UnLoadSeg (at process exit) doesn't try to free it
	; a second time, free it, then jump into the now-fully-decompressed,
	; fully-relocated program. This is the whole point of the two-hunk
	; design: unlike the old single-allocation scheme's loaded hunk
	; (never freed - docs/memory-lifecycle.md's "What never happens"),
	; this hunk genuinely is scratch space once Depack/RelocFixup are
	; done with it, and Shrinkler's own default decrunch header proves
	; it's safe to reclaim exactly this way (docs/memory-lifecycle.md's
	; "Comparison" section).
	clr.l	-4(a4)			; hunk 0's own chain pointer no longer references this hunk

	lea	Start(pc),a3		; a3 = this hunk's own base (its data start)
	move.l	-8(a3),d0		; this hunk's own total AllocMem'd size (already includes the 8-byte overhead FreeMem expects)
	lea	-8(a3),a1		; a1 = this hunk's own block base
	jsr	EXEC_FreeMem(a6)

	jmp	(a4)

Fail:
	; docs/format-spec.md §8: no recovery behavior defined for v0 (only
	; one major version exists so far) - hang rather than run off into
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
