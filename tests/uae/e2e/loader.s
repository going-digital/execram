; Test-only disk-reading boot loader for tests/uae/e2e.
;
; tests/uae/boot/sentinel.s's plain hardware-banging boot block only has
; 1024 bytes total to work with, which is fine for that tiny smoke test
; but nowhere near enough once a real depacker stub is involved (the
; inflate stub alone is already over 1KB). This loader instead reads an
; execram container (stub+header+payload, of whatever size) from the
; disk, starting right after this boot block, into a Chip RAM buffer,
; and jumps to it - the container's own stub takes it from there exactly
; as it would if AmigaDOS had LoadSeg'd it into memory itself.
;
; Disk-reading mechanics (IORequest field offsets, DoIO usage) adapted
; from Keir Fraser's bootblock.S:
;   https://github.com/keirf/Amiga-Stuff/blob/master/base/bootblock.S
;   commit fdf7f28e6eb8e6084581df083d37d363052527fd (audited 2026-09-11,
;   see docs/LICENSES.md #4 - Unlicense/public domain, no conditions).
; Simplified from that reference: it goes on to copy a decompressor
; elsewhere and run it in place, since its payload area gets overwritten
; during decompression; ours doesn't need that; loading the container is
; the only prior step - decompression is exactly what the container's
; own stub (already proven by run_boot_test.sh's simpler cousin) does
; once we jump to it.
;
; PAYLOAD_LEN (the container's exact byte length) must be supplied on
; vasm's command line via -DPAYLOAD_LEN=<n> - see run_e2e_test.sh.

EXEC_AllocMem	=	-198
EXEC_DoIO	=	-456

IO_COMMAND	=	28
IO_ERROR	=	31
IO_LENGTH	=	36
IO_DATA		=	40
IO_OFFSET	=	44
CMD_READ	=	2

MEMF_CHIP	=	2
MEMF_ANY	=	0

; A real AmigaDOS CLI/Workbench launch gives a program several KB of
; stack (dc_StackSize in the CLI process, or WBStartup's own default) -
; this bare-metal loader otherwise leaves A7 wherever Kickstart's own
; tiny boot-time supervisor stack happened to be, which is sized only
; for the trackdisk-read bootstrap this file itself does, not for
; running an arbitrary 220KB+ program afterward. A C-compiled program
; with any nontrivial call depth or local-array usage in its own
; startup code could overflow that small inherited stack, corrupting
; whatever's below it - test-only stack size, generous on purpose.
STACK_SIZE	=	16384

	section	boot,code

	dc.b	'DOS',0		; +0  id (flags byte unused, no filesystem)
	dc.l	0		; +4  checksum - patched by build_disk.py
	dc.l	0		; +8  root block pointer - unused

start:				; +12: entry point, A1 = trackdisk IORequest
	move.l	a1,a2		; a2 = IORequest, preserved

	; trackdisk.device's CMD_READ requires a sector-aligned (512-byte
	; multiple) length - round PAYLOAD_LEN up. The extra bytes read
	; past the real container are always zero (build_disk.py writes it
	; into an otherwise-zeroed ADF) and never examined: the container's
	; own header says exactly how many of its bytes are real.
	move.l	#PAYLOAD_LEN+511,d0
	and.l	#$FFFFFE00,d0

	move.l	4.w,a6		; ExecBase
	moveq	#MEMF_CHIP,d1	; disk DMA can't reach Fast RAM
	jsr	EXEC_AllocMem(a6)
	tst.l	d0
	beq.w	error
	move.l	d0,a3		; a3 = destination buffer, preserved

	move.l	a3,IO_DATA(a2)
	move.l	#PAYLOAD_LEN+511,d0
	and.l	#$FFFFFE00,d0
	move.l	d0,IO_LENGTH(a2)
	move.l	#1024,IO_OFFSET(a2)	; container starts right after this boot block
	move.w	#CMD_READ,IO_COMMAND(a2)
	move.l	a2,a1
	jsr	EXEC_DoIO(a6)
	tst.b	IO_ERROR(a2)
	bne.w	error

	; Give the program a proper-sized stack, matching (generously) what
	; a real CLI/Workbench launch would provide - see STACK_SIZE's own
	; comment above for why this bare-metal loader can't just leave A7
	; where Kickstart's own tiny boot-time stack put it.
	move.l	#STACK_SIZE,d0
	moveq	#MEMF_ANY,d1
	jsr	EXEC_AllocMem(a6)
	tst.l	d0
	beq.w	error
	add.l	#STACK_SIZE,d0		; A7 = top of the new stack (grows down)
	move.l	d0,a7

	; Real AmigaDOS launches a program with A0/D0 meaningful (a
	; Workbench startup message pointer, or a CLI command-line
	; pointer+length) - this bare-metal loader has no such message or
	; command line to hand over, and leaves both registers holding
	; whatever Kickstart's own boot-block calling convention put there
	; (garbage, from a launched program's perspective). A program that
	; checks `if (A0 != NULL)` before dereferencing it as a Workbench
	; message (the standard, safe pattern most real Amiga programs use)
	; would misinterpret that leftover value as a real pointer and
	; crash on that basis alone. Zeroing both matches the "launched
	; with no Workbench message and no command-line arguments"
	; convention every well-behaved Amiga program should already
	; handle safely.
	;
	; Neither this nor the stack size above turned out to explain the
	; crash that motivated adding them (tests/corpus/hexagon.exe hit an
	; identical fault with and without both) - that one's real cause
	; (a library call dispatched through a not-yet-open library base, a
	; bug in the program's own startup order) needed a genuine AmigaDOS
	; environment to even reach, which this loader was never going to
	; provide - see tests/uae/run_real_exe_test.sh instead, and its own
	; header for the full story. Both changes are kept anyway: they're
	; real correctness improvements for launching any program this way,
	; independent of what they did or didn't explain.
	suba.l	a0,a0
	moveq	#0,d0
	jmp	(a3)

error:
	bra.s	error
