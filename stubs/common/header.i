; Shared constants for the execram v0 container header
; (docs/format-spec.md §3). Included by runtime.i and by backends that
; need to inspect header fields directly.

HDR_MAGIC		=	0
HDR_VERSION_MAJOR	=	4
HDR_VERSION_MINOR	=	5
HDR_BACKEND_ID		=	6
HDR_FLAGS		=	7
HDR_HEADER_SIZE		=	8
HDR_CODE_DATA_SIZE	=	12
HDR_BSS_SIZE		=	16
HDR_RELOC_STREAM_SIZE	=	20
HDR_COMPRESSED_SIZE	=	24
HDR_SAFETY_MARGIN	=	28
; Bytes of stubs/common/trampoline.s's own assembled body - always the
; same fixed, backend-agnostic value for a given execram build, but data
; the stub reads rather than a manifest constant baked into this file:
; docs/format-spec.md §8b's OverlapPayloadOffset needs it (room for the
; trampoline itself must be reserved before the payload's own tail
; position within hunk 0), and a hardcoded copy here could silently
; drift from the real embedded trampoline.s's size with no assembler-
; level check to catch it. Unused by the disjoint layout's own Start:,
; but always present and written (docs/format-spec.md §9: additive,
; ignored where not needed, same as any other field here).
HDR_TRAMPOLINE_SIZE	=	32

MAGIC			=	$45784372	; "ExCr"
VERSION_MAJOR_V0	=	0

FLAG_MEM_CHIP		=	1
FLAG_HAS_RELOCS		=	2
; Purely informational as of docs/format-spec.md's in-loop flicker
; redesign: this file's own embedded stub either has the flicker baked
; into its hot decode loop or it doesn't - there is no runtime branch
; here anymore (Depack: itself differs between the plain and flash-
; instrumented stub binaries, chosen once at pack time - see
; src/main.zig's packWithBackend). This bit exists so `execram info` can
; report whether a given packed file uses it, nothing else reads it.
FLAG_FLASH		=	4
; True overlap-in-place decompression (docs/format-spec.md §8, §10):
; the compressed payload lives at hunk 0's own tail instead of in hunk
; 1, and HDR_SAFETY_MARGIN is a real, meaningful value instead of the
; always-0 it is when this flag is clear.
FLAG_OVERLAP		=	8
; Only meaningful when FLAG_FLASH is set: redirects the in-loop flicker
; target from COLOR19 ($dff1a6, the mouse pointer sprite's own middle
; color - the default, invisible-pointer-safe choice) to COLOR00
; ($dff180, the border/background color) instead. Read once per
; instrumented backend's own stub_*_flash.s wrapper, before the header
; pointer register gets repurposed for that backend's own decompression
; work - see that wrapper's own comment for exactly where.
FLAG_KILLTWITCH		=	16

RELOC_STREAM_END	=	$FE
RELOC_STREAM_ESCAPE	=	$FF
