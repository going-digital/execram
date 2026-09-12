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

	jmp	(a3)

error:
	bra.s	error
