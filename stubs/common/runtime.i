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

Start:
	lea	StubEnd(pc),a2		; a2 = header base, preserved throughout

	cmp.l	#MAGIC,HDR_MAGIC(a2)
	bne.w	Fail			; the FLAG_OVERLAP payload-offset block between here and Fail: no longer fits a short branch
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
	move.w	HDR_HEADER_SIZE(a2),d1		; d1 = header_size (used by the disjoint branch below only)
	move.l	HDR_COMPRESSED_SIZE(a2),d0	; d0 = compressed_size - Depack's own D0 input; stays raw/unrounded throughout, whichever branch below runs

	; docs/format-spec.md §8b: FLAG_OVERLAP selects true overlap-in-place
	; decompression - the compressed payload lives at a computed tail
	; offset within `final` (hunk 0) itself, placed there on disk by
	; container.zig's buildOverlapHunk0Body, instead of right after
	; the header in this (hunk 1) scratch hunk as the disjoint layout
	; below always has. Everything else in this file - RelocFixup,
	; BSS-clear, detach+free (below), even the trampoline-supplied A4
	; itself - is identical either way: `final` and this hunk's own
	; header are still two disjoint memory regions in both modes, so
	; nothing about their own safety changes; only where Depack's own
	; input pointer (A0) is found differs.
	btst	#3,HDR_FLAGS(a2)	; FLAG_OVERLAP
	beq.s	.disjoint_payload
	bsr.w	OverlapPayloadOffset	; defined near the end of this file, well past short-branch range - D2 = payload_offset, D4 = align4(compressed_size)
	bsr.w	OverlapMovePayload	; relocates the payload from its cheap on-disk position (right after the trampoline) to its margin-safe tail position (D2) - see that routine's own comment for why this step exists at all

	lea	0(a4,d2.l),a0		; a0 = compressed payload, now safely positioned within final itself
	bra.s	.havepayload
.disjoint_payload:
	lea	0(a2,d1.l),a0		; a0 = compressed payload, right after the header
.havepayload:
	move.l	a4,a1			; a1 = output = final, directly

	; FLAG_FLASH no longer branches on anything here - it's purely
	; informational now (docs/format-spec.md's in-loop flicker redesign):
	; a flash-instrumented packed file simply embeds a different Depack:
	; altogether (each backend's own stub_*_flash.s), with the flicker
	; baked directly into its hot decode loop. See that file's own
	; comment for where/how, and header.i's own FLAG_FLASH/FLAG_KILLTWITCH
	; comments for the full rationale.
	bsr.w	Depack

	btst	#1,HDR_FLAGS(a2)	; FLAG_HAS_RELOCS
	beq.s	.norelocs
	bsr.s	RelocFixup		; measured 48 bytes away - fits a short branch
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
	; docs/format-spec.md §7 does not align the escape's 4-byte
	; big-endian payload to any boundary - it can legally start at an
	; odd offset from the reloc-stream's own start, since every
	; preceding record is a variable 1-or-5-byte run with no padding.
	; A single `move.l (a5)+,d1` here is a real 68000 Address Error
	; (vector 3) whenever that happens - confirmed by reproducing it
	; under genuine FS-UAE A500 (68000) emulation, not just a real
	; machine (this is very likely the actual cause of the real-
	; hardware failure that motivated this fix). Read it byte-by-byte
	; instead: legal at any address.
	moveq	#0,d1
	move.b	(a5)+,d1
	lsl.l	#8,d1
	move.b	(a5)+,d1
	lsl.l	#8,d1
	move.b	(a5)+,d1
	lsl.l	#8,d1
	move.b	(a5)+,d1
.havehalf:
	lsl.l	#1,d1			; delta = half_delta * 2
	add.l	d1,d6
	move.l	(a4,d6.l),d2
	add.l	a4,d2
	move.l	d2,(a4,d6.l)
	bra.s	.next
.done:
	rts

; docs/format-spec.md §8b's overlap-mode payload positioning, only ever
; reached when FLAG_OVERLAP is set. Recomputes the same tail offset
; container.zig's own overlapAllocatedSize already used to place the
; payload on disk (so the two can never drift apart), entirely from
; header fields - no LoadSeg ABI dependency of any kind (unlike this
; file's own free-hunk-1 step below, this routine runs on hunk 1's own,
; still perfectly ordinary header - nothing overlap-specific about
; *reading* it, only about where the payload it describes lives).
;
; In: D0 = compressed_size, A2 = header base. Out: D2 = payload_offset
; (bytes from `final`'s own base to where the payload starts), D4 =
; align4(compressed_size) (OverlapMovePayload's own copy length input,
; below). Clobbers D1/D3; leaves D0 - the caller's own Depack input -
; untouched.
;
; Uses align4(compressed_size), not the raw value, throughout: the
; caller's own `final + payload_offset` must always land on a 4-byte
; boundary, or the first word/long access any backend's Depack makes
; via A0 is a genuine 68000 Address Error (confirmed on real hardware -
; see the commit that found this) whenever compressed_size itself is
; odd. Rounding up costs at most 3 bytes of harmless trailing padding
; after the real payload.
OverlapPayloadOffset:
	move.l	d0,d2
	addq.l	#3,d2
	and.l	#-4,d2			; d2 = align4(compressed_size)
	move.l	d2,d4			; d4 = align4(compressed_size), preserved for OverlapMovePayload's own use below (d2 itself gets overwritten with payload_offset further down)

	; d1 = resident_tail_size = align4(code_data_size + max(bss_size, reloc_stream_size))
	; - running max accumulator from here on.
	move.l	HDR_BSS_SIZE(a2),d1
	move.l	HDR_RELOC_STREAM_SIZE(a2),d3
	cmp.l	d3,d1
	bge.s	.residtail_have_max
	move.l	d3,d1
.residtail_have_max:
	add.l	HDR_CODE_DATA_SIZE(a2),d1
	addq.l	#3,d1
	and.l	#-4,d1			; d1 = resident_tail_size

	; d3 = on_disk_len = trampoline_size + align4(compressed_size): the
	; trampoline itself (hunk 0's own on-disk prefix, always present
	; ahead of the payload - stubs/common/trampoline.s, buildOverlapHunk0Body)
	; must physically fit before the payload's own tail-aligned start.
	; Without this bound, a backend whose compressed_size ends up close
	; to resident_tail_size (store, e.g. - it never shrinks the input at
	; all, so its own compressed_size routinely equals resident_tail_size
	; exactly) can compute a payload_offset of 0 or less, overlapping the
	; trampoline itself - a real bug found on real hardware (git
	; history) before this bound was added.
	move.l	HDR_TRAMPOLINE_SIZE(a2),d3
	add.l	d2,d3
	cmp.l	d3,d1
	bge.s	.have_second_max
	move.l	d3,d1
.have_second_max:

	; d3 = overlap_min = safety_margin + align4(compressed_size)
	move.l	HDR_SAFETY_MARGIN(a2),d3
	add.l	d2,d3

	; d1 = align4(max(d1, overlap_min)) = allocated_size
	cmp.l	d3,d1
	bge.s	.have_allocated_size
	move.l	d3,d1
.have_allocated_size:
	addq.l	#3,d1
	and.l	#-4,d1			; d1 = allocated_size

	sub.l	d2,d1			; d1 = allocated_size - align4(compressed_size) = payload_offset
	move.l	d1,d2			; d2 = payload_offset (return value)
	rts

; Relocates the compressed payload from its cheap on-disk position
; (final + trampoline_size, right after the trampoline -
; buildOverlapHunk0Body's own on-disk layout, container.zig) to its
; margin-safe tail position (final + payload_offset), before Depack
; runs - so hunk 0's own on-disk body only ever needs to hold
; trampoline_size + compressed_size bytes, not payload_offset +
; compressed_size. The earlier design put the payload directly at
; payload_offset on disk, skipping this step entirely - but that meant
; every byte between the trampoline's end and payload_offset had to be
; materialized as literal zero padding in the packed file, since
; AmigaDOS's own "declared hunk size > on-disk data length" trick only
; ever leaves the *tail* of a hunk's allocation implicit, never a gap
; in the middle. For any backend with a real compression ratio,
; payload_offset ends up close to the full decompressed size (the
; margin approaches decompressed_size - compressed_size for uniformly-
; compressible data), so that on-disk padding very nearly cancelled out
; the entire compression gain - a real, reported bug (shrinkler on a
; 221KB real program: packed file 218848 bytes vs. 142120 without
; --overlap). Shrinkler's own `--overlap` mode (docs/memory-lifecycle.md's
; "Comparison" section, `HunkFile.h`'s per-hunk decrunch header) already
; does exactly this relocation - its own decrunch header does the same
; on-disk-cheap-position -> runtime-safe-position memmove per hunk
; before decompressing that hunk in place.
;
; In: A2 = header base, A4 = final (resident base), D2 = payload_offset,
; D4 = align4(compressed_size) - both straight from
; OverlapPayloadOffset's own return values, unmodified. Out: none - D2
; (the caller's own next use, right after this returns) is left
; untouched; D0/A2/A4 also untouched. Clobbers D1/D3/A0/A1.
;
; A no-op (copies onto itself, byte for byte) whenever payload_offset
; equals trampoline_size exactly (e.g. store, which measures a 0-byte
; overlap margin - docs/algorithm-notes/store.md). Otherwise dest
; (payload_offset) is always >= src (trampoline_size):
; OverlapPayloadOffset's own on_disk_len bound
; (trampoline_size + align4(compressed_size) <= allocated_size)
; guarantees payload_offset can never land below trampoline_size. So
; copying backward (highest address first, `move.l -(a0),-(a1)`) is
; always the correct, safe direction here regardless of how much the
; source and destination regions overlap - the standard rule for an
; in-place memmove where dest >= src.
OverlapMovePayload:
	tst.l	d4
	beq.s	.done			; nothing to move (a zero-length payload, if that's ever legal for some backend/input)
	move.l	HDR_TRAMPOLINE_SIZE(a2),d3
	lea	0(a4,d3.l),a0
	adda.l	d4,a0			; a0 = src end (one past the last on-disk payload byte)
	lea	0(a4,d2.l),a1
	adda.l	d4,a1			; a1 = dest end (one past the last safe-position byte)
	lsr.l	#2,d4			; d4 = longword count (guaranteed exact: d4 was already align4'd)
.moveloop:
	move.l	-(a0),-(a1)
	subq.l	#1,d4
	bne.s	.moveloop
.done:
	rts

; NOTE: StubEnd is NOT defined here. runtime.i is `include`d before each
; backend's own Depack code, so a label placed here would land at the
; start of Depack, not at the true end of the assembled stub - that was
; a real bug, caught by tests/uae/e2e's boot test (see that script's
; history/commit message). Each backend's stub.s must define
; `even` / `StubEnd:` itself, after its own Depack routine.
