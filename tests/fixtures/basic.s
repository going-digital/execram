; Small multi-hunk test program used by src/hunk.zig's unit tests. Built
; at `zig build test` time (vasm assembles to a linkable object, vlink
; links it into a real AmigaDOS load-file executable - see build.zig) so
; the parser is tested against real, independently-verified hunk bytes
; rather than a hand-rolled fixture that might share the parser's own
; assumptions/bugs.
;
; Exercises: three hunks (CODE/DATA/BSS), a RELOC32 from CODE into both
; DATA and BSS, and a RELOC32 from DATA into BSS - enough to validate
; relocation parsing across hunk boundaries without needing a real,
; large program.

	section	CODE,code
start:
	moveq	#0,d0
	lea	msg(pc),a0
	move.l	dataptr,a1
	move.l	(a1),d1
	move.l	#bssvar,a2
	rts

msg:
	dc.b	'hi',0
	even

	section	DATA,data
dataptr:
	dc.l	bssvar
someval:
	dc.l	$12345678

	section	BSS,bss
bssvar:
	ds.l	4
