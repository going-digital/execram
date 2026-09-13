; std-syntax (vasm's GNU-as-style module) copy of ../common/header.i -
; same constants, only the directive spelling differs (.equ instead of
; mot-syntax's bare "=", 0x hex instead of $ hex, which std syntax
; parses as a symbol name rather than a literal - see the inflate
; backend's README for why this stub needs std syntax at all).
;
; Keep in sync with ../common/header.i by hand; there's no good way to
; share one file across vasm's mot and std syntax modules (confirmed by
; testing - they parse just differently enough, in just enough small
; ways, that neither file works unmodified under the other).

.equ HDR_MAGIC,0
.equ HDR_VERSION_MAJOR,4
.equ HDR_VERSION_MINOR,5
.equ HDR_BACKEND_ID,6
.equ HDR_FLAGS,7
.equ HDR_HEADER_SIZE,8
.equ HDR_CODE_DATA_SIZE,12
.equ HDR_BSS_SIZE,16
.equ HDR_RELOC_STREAM_SIZE,20
.equ HDR_COMPRESSED_SIZE,24
.equ HDR_SAFETY_MARGIN,28

.equ MAGIC,0x45784372
.equ VERSION_MAJOR_V0,0

.equ FLAG_MEM_CHIP,1
.equ FLAG_HAS_RELOCS,2
.equ FLAG_FLASH,4

.equ RELOC_STREAM_END,0xFE
.equ RELOC_STREAM_ESCAPE,0xFF
