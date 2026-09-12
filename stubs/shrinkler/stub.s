; "shrinkler" backend depacker stub: real Shrinkler decompression via a
; vendored Aske Simon Christensen depacker (ShrinklerDecompress.s - see
; that file for provenance/license/trims).
;
; Unlike unzx0_68000.s (zx0 backend) or inflate_core.s (inflate
; backend), ShrinklerDecompress needs more setup than runtime.i's plain
; Depack contract (A0/A1/D0 in) provides: a progress-callback pointer
; in A2 (zero to disable) and a parity-context flag in D7. Both are
; fixed choices, not values carried in execram's own container header -
; see src/backends/shrinkler_vendor/shrinkler_shim.cpp's own comment on
; why: they must agree bit-for-bit between host encoder and this
; depacker, and there's nowhere in the container format to carry a
; per-file choice, so both sides hardcode the same constants instead.
;
; A2 must be SAVED and RESTORED around the call, not just zeroed: this
; project's own runtime.i keeps the container's header base in A2
; across the whole Start routine (`lea StubEnd(pc),a2 ; a2 = header
; base, preserved throughout`), reading HDR_CODE_DATA_SIZE/HDR_BSS_SIZE
; through it again right after `bsr.w Depack` returns. ShrinklerDecompress's
; own header comment claims to "preserve D2-D7/A2-A6" - true in the
; sense that its body never WRITES A2/A3 (they're read-only progress-
; callback inputs, per its own `movem.l d2-d7/a4-a6,-(a7)`, which
; conspicuously does NOT list a2/a3 - they need no save/restore from
; ShrinklerDecompress's own perspective, since it never touches them),
; but that guarantee is worthless if *this* stub hands it a *different*
; A2 value than the one runtime.i is still relying on. Confirmed as a
; real bug, not a hypothetical: an early version of this stub zeroed A2
; without saving it first, which silently corrupted every header field
; read after decompression (wrong AllocMem size for the final,
; decompressed-output buffer) - passed every host-side test (the C++
; round-trip test and even a real-hardware test that called
; ShrinklerDecompress directly, bypassing runtime.i entirely) and only
; failed in the full pack -> boot -> decompress -> relocate -> jump
; pipeline, silently (a corrupted/garbage AllocMem size either fails
; outright or produces nonsense, both indistinguishable from a hang at
; the serial-output level) - see the commit message for the full
; debugging trail.

	include	"../common/runtime.i"

Depack:
	move.l	a2,-(sp)		; save the real header base
	suba.l	a2,a2			; no progress callback
	moveq	#1,d7			; parity context on (Shrinkler's own --data default)
	bsr.w	ShrinklerDecompress
	move.l	(sp)+,a2		; restore it for runtime.i's own later use
	rts

	include	"ShrinklerDecompress.s"

	even
StubEnd:
