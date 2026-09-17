; "store" backend depacker stub, flash-instrumented variant
; (docs/format-spec.md's in-loop decompression flicker): identical to
; stub.s except for depack_core_flash.s instead of depack_core.s - see
; that file's own header comment for what differs and why.

	include	"runtime.i"		; resolved via vasm's -I stubs/common (build.zig)
	include	"depack_core_flash.s"

	even
StubEnd:
