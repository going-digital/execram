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

MAGIC			=	$45784372	; "ExCr"
VERSION_MAJOR_V0	=	0

FLAG_MEM_CHIP		=	1
FLAG_HAS_RELOCS		=	2

RELOC_STREAM_END	=	$FE
RELOC_STREAM_ESCAPE	=	$FF
