; "zx0" backend depacker stub, flash-instrumented variant
; (docs/format-spec.md's in-loop decompression flicker): identical to
; stub.s except for unzx0_68000_flash.s instead of unzx0_68000.s - see
; that file's own header comment for what differs and why.

	include	"../common/runtime.i"
	include	"unzx0_68000_flash.s"

	even
StubEnd:
