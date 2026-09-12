; End-to-end test payload for the store backend's runtime stub
; (stubs/store/stub.s + stubs/common/runtime.i). Packed with the real
; `execram pack` CLI, then boot-tested in FS-UAE (see run_e2e_test.sh) -
; if AllocMem, the copy, and the reloc-fixup all did their job, this
; prints its sentinel via a pointer that only has the right value
; because a self-hunk RELOC32 (msgptr -> message, both in the DATA
; hunk) was correctly relocated by the packed program's runtime stub,
; not by anything at pack time. A wrong or skipped reloc reads garbage
; here and either hangs or writes nonsense to the serial port instead
; of the sentinel - this is a real functional check, not just "did it
; not crash".

	section	CODE,code
start:
	move.w	#$7fff,$dff09a		; INTENA: quiet down interrupts
	move.w	#$7fff,$dff09c		; INTREQ: clear pending
	move.w	#368,$dff032		; SERPER: ~9600 baud, PAL (see tests/uae/boot/sentinel.s)

	move.l	msgptr,a0		; the pointer this whole test is about
.next:
	move.b	(a0)+,d0
	beq.s	.hang
	bsr.s	sendchar
	bra.s	.next
.hang:
	bra.s	.hang

sendchar:
	or.w	#$100,d0
	move.w	d0,$dff030
	move.l	#20000,d1
.delay:
	subq.l	#1,d1
	bne.s	.delay
	rts

	section	DATA,data
msgptr:
	dc.l	message			; RELOC32 onto this same DATA hunk
message:
	dc.b	'EXECRAM-PACKED-OK',10,0
	even
