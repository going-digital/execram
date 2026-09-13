; Test-only disk-reading boot loader for tests/uae/e2e.
;
; tests/uae/boot/sentinel.s's plain hardware-banging boot block only has
; 1024 bytes total to work with, which is fine for that tiny smoke test
; but nowhere near enough once a real depacker stub is involved (the
; inflate stub alone is already over 1KB). This loader instead reads an
; execram-packed executable (docs/format-spec.md §2, whatever its size)
; from disk, starting right after this boot block, into a scratch Chip
; RAM buffer, then rebuilds the real two-hunk in-memory layout a genuine
; AmigaDOS LoadSeg would - two separately allocated blocks, each with an
; 8-byte header (own total AllocMem'd size at +0, a BCPL-shifted pointer
; to the next hunk's own +4 field at +4, 0 if none) - before jumping into
; hunk 0's own data start, exactly as a real LoadSeg-launched program
; would begin. That ABI was confirmed against real hardware across three
; Kickstart versions (v1.3 r34.005/v2.05 r37.350/v3.1 r40.063) before
; anything depended on it - see stubs/common/runtime.i's own header
; comment and the commit that introduced this design for the probe and
; raw results.
;
; This is not a general hunk-file loader: it assumes exactly the fixed
; shape execram itself always produces (two CODE hunks, no relocations,
; no symbol/debug data), read sequentially rather than via a real
; type-dispatching parser - tests/uae/e2e/extract_container.py validates
; that shape before this ever runs.
;
; Disk-reading mechanics (IORequest field offsets, DoIO usage) adapted
; from Keir Fraser's bootblock.S:
;   https://github.com/keirf/Amiga-Stuff/blob/master/base/bootblock.S
;   commit fdf7f28e6eb8e6084581df083d37d363052527fd (audited 2026-09-11,
;   see docs/LICENSES.md #4 - Unlicense/public domain, no conditions).
;
; PAYLOAD_LEN (the whole packed file's exact byte length) must be
; supplied on vasm's command line via -DPAYLOAD_LEN=<n> - see
; run_e2e_test.sh.

EXEC_AllocMem	=	-198
EXEC_FreeMem	=	-210
EXEC_DoIO	=	-456

IO_COMMAND	=	28
IO_ERROR	=	31
IO_LENGTH	=	36
IO_DATA		=	40
IO_OFFSET	=	44
CMD_READ	=	2

MEMF_CHIP	=	2
MEMF_ANY	=	0
MEMF_CLEAR	=	$10000
; Bit 30 of a hunk-size-table longword's low 30 bits/top 2 bits split -
; matches src/container.zig's own MEMF_CHIP_BIT and src/hunk.zig's
; MemAttr encoding (docs/format-spec.md §2).
MEMF_CHIP_BIT	=	$40000000
SIZE_MASK	=	$3FFFFFFF

HUNK_CODE	=	$3E9

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

	; --- read the whole packed file into a scratch Chip RAM buffer ---
	; trackdisk.device's CMD_READ requires a sector-aligned (512-byte
	; multiple) length - round PAYLOAD_LEN up. The extra bytes read
	; past the real file are always zero (build_disk.py writes it into
	; an otherwise-zeroed ADF) and never examined.
	move.l	#PAYLOAD_LEN+511,d0
	and.l	#$FFFFFE00,d0
	move.l	d0,d7			; d7 = this buffer's own AllocMem size, kept for the FreeMem below

	move.l	4.w,a6			; ExecBase, kept throughout
	moveq	#MEMF_CHIP,d1		; disk DMA can't reach Fast RAM
	jsr	EXEC_AllocMem(a6)
	tst.l	d0
	beq.w	error
	move.l	d0,a3			; a3 = scratch buffer base, preserved

	move.l	a3,IO_DATA(a2)
	move.l	d7,IO_LENGTH(a2)
	move.l	#1024,IO_OFFSET(a2)	; the packed file starts right after this boot block
	move.w	#CMD_READ,IO_COMMAND(a2)
	move.l	a2,a1
	jsr	EXEC_DoIO(a6)
	tst.b	IO_ERROR(a2)
	bne.w	error

	; --- parse the two-hunk file and rebuild LoadSeg's own layout ---
	lea	20(a3),a0		; skip HUNK_HEADER/reslist/table_size/first_hunk/last_hunk (5 longwords)
	move.l	(a0)+,d2		; d2 = hunk 0's declared size+flags
	move.l	(a0)+,d1		; d1 = hunk 1's declared size+flags - stashed on the stack until needed
	move.l	d1,-(a7)
	addq.l	#4,a0			; skip hunk 0's own HUNK_CODE marker
	move.l	(a0)+,d4		; d4 = hunk 0's own real body size, in longwords

	; AllocHunk's own code only touches D0/D1/D3/A1, but the real
	; EXEC_AllocMem call it makes inside is standard Amiga library code,
	; free to clobber A0/A1/D0/D1 same as any other LVO call - confirmed
	; the hard way (a real bug here, not a theoretical one): without
	; this save/restore, A0 (our own read position in the scratch
	; buffer) came back clobbered after the call, and both hunks' real
	; bodies silently "copied" as all-zero (MEMF_CLEAR's own fill,
	; untouched, since CopyLongs then read from wherever A0 actually
	; ended up instead) rather than their real bytes - found by dumping
	; the constructed blocks' own memory over serial before the jump and
	; seeing 0 where the trampoline's/stub's real first instruction
	; bytes belonged.
	move.l	a0,-(a7)
	bsr.w	AllocHunk		; in: d2; out: a1 = hunk 0's new block, its own size already written at +0
	move.l	(a7)+,a0
	move.l	a1,a4			; a4 = hunk 0's block base, kept to the end (its data start is the final jump target)
	lea	8(a4),a1
	move.l	d4,d0
	bsr.w	CopyLongs		; hunk 0's real on-disk body -> its own block+8; a0 left just past it
	lea	8(a0),a0		; skip HUNK_END + hunk 1's own HUNK_CODE marker

	move.l	(a7)+,d2		; d2 = hunk 1's declared size+flags
	move.l	(a0)+,d4		; d4 = hunk 1's own real body size, in longwords
	move.l	a0,-(a7)		; A0 must survive the nested EXEC_AllocMem call - see the comment at the first AllocHunk call site
	bsr.w	AllocHunk		; out: a1 = hunk 1's new block
	move.l	(a7)+,a0
	move.l	a1,a5			; a5 = hunk 1's block base
	lea	8(a5),a1
	move.l	d4,d0
	bsr.w	CopyLongs		; hunk 1's real on-disk body -> its own block+8

	; Link hunk 0 -> hunk 1, exactly as a real LoadSeg would: hunk 0's
	; own chain-pointer field (+4) gets a BCPL-shifted pointer to hunk
	; 1's own +4 field (see this file's own header comment for the ABI).
	move.l	a5,d0
	addq.l	#4,d0
	lsr.l	#2,d0
	move.l	d0,4(a4)

	; The scratch disk-read buffer has served its purpose - free it,
	; same discipline stubs/common/runtime.i's own hunk-1-freeing logic
	; follows for the real thing.
	move.l	a3,a1
	move.l	d7,d0
	jsr	EXEC_FreeMem(a6)

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
	; (garbage, from a launched program's perspective). Zeroing both
	; matches the "launched with no Workbench message and no
	; command-line arguments" convention every well-behaved Amiga
	; program should already handle safely.
	suba.l	a0,a0
	moveq	#0,d0
	lea	8(a4),a1		; hunk 0's own data start - exactly where a genuine LoadSeg-launched program's entry point would be
	jmp	(a1)

error:
	bra.s	error

; AllocHunk: allocates one hunk's real AmigaDOS-style block and writes
; its own size at +0 (the +4 chain-pointer field is the caller's job -
; only the caller knows what, if anything, comes next).
; In:  D2.l = declared size+flags longword (low 30 bits = size in
;             longwords, bit 30 = MEMF_CHIP - docs/format-spec.md §2 /
;             src/container.zig's own encoding)
; Out: A1.l = new block's base address
; Clobbers D0/D1/D3 directly, and - via the real EXEC_AllocMem call
; inside - anything else a standard Amiga library call is free to
; clobber (A0/A1/D0/D1); callers must save/restore A0 themselves if they
; still need it afterward (see both call sites above - a real bug here
; once, not a theoretical warning).
AllocHunk:
	move.l	d2,d3
	and.l	#SIZE_MASK,d3
	lsl.l	#2,d3
	addq.l	#8,d3			; d3 = total block size, including this 8-byte header
	move.l	#MEMF_CLEAR,d1
	btst	#30,d2
	beq.s	.notchip
	or.l	#MEMF_CHIP,d1
.notchip:
	move.l	d3,d0
	jsr	EXEC_AllocMem(a6)
	tst.l	d0
	beq.w	error
	move.l	d0,a1
	move.l	d3,(a1)
	rts

; CopyLongs: In: A0 = src, A1 = dst, D0.l = longword count. Both
; pointers are left just past the copied region on return. Clobbers
; nothing else.
CopyLongs:
	tst.l	d0
	beq.s	.done
.loop:	move.l	(a0)+,(a1)+
	subq.l	#1,d0
	bne.s	.loop
.done:	rts
