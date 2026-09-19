; Boot regression for a 512K Chip + 512K Slow A500. The harness increases
; CODE's allocation to 220000 bytes without adding bytes to its body.
; Promoting all regions to Chip requires ~492K before OS/depacker needs.
	section CODE,code
start:
	move.l tailptr,a0
	move.l #$12345678,(a0)
	cmp.l #$12345678,(a0)
	bne.w fail
	move.l chipptr,a0
	move.l a0,d0
	cmp.l #$80000,d0
	bhs.w fail
	cmp.l #$10203040,(a0)
	bne.w fail
	move.l backlink,a0
	lea start(pc),a1
	cmpa.l a1,a0
	bne.w fail
	move.l bssptr,a0
	move.l a0,d0
	cmp.l #$80000,d0
	bhs.w fail
	move.l #8192,d1
.check:
	tst.l (a0)+
	bne.w fail
	subq.l #1,d1
	bne.s .check
	lea ok(pc),a0
	bra.s report
fail:
	lea bad(pc),a0
report:
	move.w #368,$dff032
.next:
	moveq #0,d0
	move.b (a0)+,d0
	beq.s .done
	or.w #$100,d0
	move.w d0,$dff030
	move.l #20000,d1
.delay:
	subq.l #1,d1
	bne.s .delay
	bra.s .next
.done:
	moveq #0,d0
	rts
ok:
	dc.b 'EXECRAM-MIXED-OK',10,0
bad:
	dc.b 'EXECRAM-MIXED-FAIL',10,0
	even
tailptr:
	dc.l start+210000
chipptr:
	dc.l chipdata
bssptr:
	dc.l chipbss
	section CHIP,data_c
chipdata:
	dc.l $10203040
backlink:
	dc.l start
	ds.b 239992
	section CHIPBSS,bss_c
chipbss:
	ds.l 8192
