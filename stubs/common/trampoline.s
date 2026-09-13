; Hunk 0's entire on-disk body, for every backend alike - the new
; two-hunk runtime (docs/memory-lifecycle.md's "Comparison" section;
; see stubs/common/runtime.i's own header comment for the full design
; and the ABI this depends on). Backend-agnostic: finding hunk 1 and
; jumping into it needs no backend-specific knowledge at all, so every
; backend shares this one assembled binary unchanged (build.zig).
;
; AmigaDOS's LoadSeg jumps here directly - this is hunk 0's own, and
; the whole packed file's, entry point. container.zig declares hunk 0
; at the *full resident size* (code_data_size + bss_size) with this
; tiny body as its only real on-disk content; the rest of that
; allocation is uninitialized until Depack fills it (fine - see
; runtime.i's own comment on why nothing here depends on prior zero
; state).
;
; Hands off A4 = hunk 0's own base address (this label's own
; PC-relative address) to hunk 1's Start - Depack's eventual output
; target, and the real program's own entry point once decompression
; finishes. Nothing else is handed off: hunk 1 locates its own header
; and its own size (for freeing itself once done) independently via its
; own PC-relative addressing, so this trampoline needs no
; backend-specific or even header-aware knowledge at all.
;
; ABI relied on below (confirmed empirically under real FS-UAE across
; Kickstart v1.3 r34.005/v2.05 r37.350/v3.1 r40.063 - see the commit
; that introduced this file for the probe and raw results): every hunk
; AmigaDOS's LoadSeg loads carries an 8-byte header immediately before
; its own "public" data - that hunk's own total AllocMem'd size in
; bytes (already including this 8-byte header) at data_start-8, and a
; BCPL-shifted pointer to the NEXT hunk's own "+4" field (0 if none) at
; data_start-4.

	section	trampoline,code

Trampoline:
	lea	Trampoline(pc),a4	; a4 = hunk 0's own base - stays live all the way to Start's final jmp (a4)
	move.l	-4(a4),d0		; hunk 0's own chain-pointer field: hunk 1's own "+4" field, BCPL-shifted
	lsl.l	#2,d0
	move.l	d0,a1
	jmp	4(a1)			; hunk 1's own data start = its "+4" field + 4
