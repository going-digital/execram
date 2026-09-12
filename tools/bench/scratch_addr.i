; Shared between fake_exec.s (assembled by vasm) and main.zig (which
; must place the returned pointer's target region here, and keep the
; stub/payload/output/stack layout entirely below it) - see both
; files' own comments. Kept in one place so the two can't drift apart
; silently; if this ever needs to change, grep for
; FAKE_EXEC_SCRATCH_BASE in tools/bench/main.zig too.
FAKE_EXEC_SCRATCH_BASE	=	$710000
