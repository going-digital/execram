; Bare-metal AmigaDOS boot block for the M0 FS-UAE smoke test.
;
; Kickstart's disk-boot code reads the first 1024 bytes of the floppy,
; checks the 'DOS' id and the checksum below, then calls the code at
; offset 12 with A1 = an open trackdisk.device IORequest (we ignore it).
; No filesystem, Exec or DOS calls are needed or used: this bangs the
; serial hardware registers directly to emit a sentinel line, then hangs.
;
; FS-UAE is configured (see ../run_boot_test.sh) to capture anything
; written to the serial port to a host file, which the harness script
; greps for the sentinel line - proving Kickstart + FS-UAE + a custom
; assembled 68k program round-trip correctly, with no OS/DOS dependency
; to complicate what the test is actually checking.
;
; Assembled with vasm to a raw binary (-Fbin); build_adf.py then pads it
; to 1024 bytes, patches in the checksum, and writes it as sector 0/1 of
; a blank ADF image.

CUSTOM		equ	$dff000
INTENA		equ	CUSTOM+$9a
INTREQ		equ	CUSTOM+$9c
SERPER		equ	CUSTOM+$32
SERDAT		equ	CUSTOM+$30

SERPER_9600_PAL	equ	(3546895/9600)-1
; Empirically-chosen delay between characters, comfortably longer than one
; byte's transmission time at 9600 baud. Polling INTREQR's TBE bit (as the
; Amiga HRM describes) never went high under FS-UAE's serial emulation in
; testing here, so this stub just paces itself with a fixed delay instead -
; fine for a one-shot sentinel message with nothing else to do meanwhile.
CHAR_DELAY	equ	20000

	section	boot,code

	dc.b	'DOS',0		; +0  id (flags byte unused, no filesystem)
	dc.l	0		; +4  checksum - patched by build_adf.py
	dc.l	0		; +8  root block pointer - unused

start:				; +12: entry point, A1 = IORequest (unused)
	move.w	#$7fff,INTENA	; quiet down interrupts, we never return
	move.w	#$7fff,INTREQ
	move.w	#SERPER_9600_PAL,SERPER

	lea	msg(pc),a0
.next_char:
	move.b	(a0)+,d0
	beq.s	.hang
	bsr.s	send_char
	bra.s	.next_char

.hang:
	bra.s	.hang

; Send the byte in d0 over the serial port (8 data bits, 1 stop bit),
; then wait out CHAR_DELAY before returning.
send_char:
	or.w	#$100,d0	; bit 8 = stop bit, per the Amiga HRM's SERDAT format
	move.w	d0,SERDAT
	move.l	#CHAR_DELAY,d1
.wait:
	subq.l	#1,d1
	bne.s	.wait
	rts

msg:
	dc.b	'EXECRAM-BOOT-OK',10,0
	even
