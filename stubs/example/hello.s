; Placeholder stub used only to prove the vasm -> Zig build pipeline works
; end to end (M0). Real depacker stubs land in stubs/inflate, stubs/zx0,
; stubs/shrinkler in later milestones.
	section	text

start:
	moveq	#42,d0
	rts
