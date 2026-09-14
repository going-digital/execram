; std-syntax mirror of ../common/runtime.i - see that file's own header
; comment for the full design (the two-hunk runtime, the trampoline
; handoff, and the ABI this depends on for finding/freeing this hunk's
; own memory). Kept in sync by hand, like ../common/header.i's own std
; copy (header_std.i) - see that file's own comment for why there's no
; good way to share one file across vasm's mot and std syntax modules.

	.include	"header_std.i"

; EXEC_AllocMem is no longer used by Start: itself (see below) - kept
; here since it's still a real Exec LVO a backend's own Depack may need
; for its own internal scratch space (this stub's own inflate decode
; window - see stub.s's own Depack), same as EXEC_FreeMem.
.equ EXEC_AllocMem,-198
.equ EXEC_FreeMem,-210

; FLAG_FLASH support (docs/format-spec.md §5) - see ../common/runtime.i's
; own comment (kept in sync by hand, like everything else in this file).
.equ CUSTOM_COLOR00,0xdff180
.equ FLASH_COLOR,0x0f00		; bright red

Start:
	lea	StubEnd(pc),a2		; a2 = header base, preserved throughout

	cmp.l	#MAGIC,HDR_MAGIC(a2)
	bne.w	Fail
	cmp.b	#VERSION_MAJOR_V0,HDR_VERSION_MAJOR(a2)
	bne.w	Fail

	move.l	4.w,a6			; ExecBase

	; No allocation at all: A4 already holds hunk 0's own base (Depack's
	; output target), handed in by ../common/trampoline.s. See that
	; file's own and ../common/runtime.i's own comments for the full
	; design and the confirmed ABI this depends on.

	; Depack(compressed payload -> final)
	moveq	#0,d1
	move.w	HDR_HEADER_SIZE(a2),d1
	lea	0(a2,d1.l),a0		; a0 = compressed payload
	move.l	a4,a1			; a1 = output = final, directly
	move.l	HDR_COMPRESSED_SIZE(a2),d0

	btst	#2,HDR_FLAGS(a2)	; FLAG_FLASH
	beq.s	.flashonskip
	move.w	#FLASH_COLOR,CUSTOM_COLOR00
.flashonskip:
	bsr.w	Depack
	btst	#2,HDR_FLAGS(a2)	; FLAG_FLASH - re-tested, not cached:
	beq.s	.flashoffskip		; Depack is free to clobber condition
	move.w	#0,CUSTOM_COLOR00	; codes along with D0/D1/A0/A1.
.flashoffskip:

	btst	#1,HDR_FLAGS(a2)	; FLAG_HAS_RELOCS
	beq.s	.norelocs
	bsr.w	RelocFixup
.norelocs:

	; Clear BSS - identical rationale to ../common/runtime.i's own (this
	; step makes no assumption about what was here before it runs, now
	; that there's no AllocMem MEMF_CLEAR at all).
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

	; Detach hunk 1 (this hunk) from hunk 0's own chain-pointer field,
	; free it, then jump into the now-fully-decompressed, fully-relocated
	; program - see ../common/runtime.i's own comment for the full
	; rationale (this is the whole point of the two-hunk redesign).
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

; NOTE: unlike mot syntax, vasm's std syntax does not scope a ".name"
; local label to the nearest preceding real label - it's a single global
; symbol, full stop. Every ".xxx" below must therefore be unique across
; this whole file, not just within its own routine (confirmed by
; testing: reusing a name already used elsewhere in this file is a
; "label redefined" error here).
;
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
.relocnext:
	moveq	#0,d1
	move.b	(a5)+,d1
	cmp.b	#RELOC_STREAM_END,d1
	beq.s	.relocdone
	cmp.b	#RELOC_STREAM_ESCAPE,d1
	bne.s	.relochalf
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
.relochalf:
	lsl.l	#1,d1			; delta = half_delta * 2
	add.l	d1,d6
	move.l	(a4,d6.l),d2
	add.l	a4,d2
	move.l	d2,(a4,d6.l)
	bra.s	.relocnext
.relocdone:
	rts

; NOTE: StubEnd is NOT defined here, same reason as ../common/runtime.i.
