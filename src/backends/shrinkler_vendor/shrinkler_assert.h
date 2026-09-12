// Copyright 1999-2015 Aske Simon Christensen. See LICENSE.txt for usage terms.

/*

An assert function which contains a breakpoint, for ease of debugging.

*/

// Renamed from upstream's own `assert.h` to `shrinkler_assert.h`, and
// the three `#include "assert.h"` sites that pull it in (Coder.h,
// LZParser.h, RangeDecoder.h) updated to match - the one deliberate
// content change across this whole vendor directory, everything else
// copied verbatim. Upstream deliberately shadows the *system*
// assert.h within its own single-translation-unit build (quote-form
// #include resolves to this file first from within Shrinkler's own
// sources - see the #undef/#define below), which is fine as long as
// this directory never sits on a *shared* compiler include path. It
// does here: @cImport's own @cInclude mechanism has no
// "including file's own directory" concept the way a real C #include
// does (see salvador_shim.h's own comment on this), so this directory
// must be on the module's global include path for
// shrinkler_shim.h to be found via @cImport - and having a file
// literally named assert.h sit on a *global* include path shadowed
// every other vendored C file's `#include <assert.h>` (angle-bracket
// form also searches -I dirs, not just the including file's own
// directory) with this non-conforming stand-in, breaking unrelated
// compilation elsewhere with cryptic "undeclared function" errors on
// fprintf/exit/stdout. Confirmed by hitting exactly that against
// salvador_vendor/libdivsufsort's own divsufsort_private.h before this
// rename.

#pragma once

void internal_error() {
	fflush(stdout);
	fprintf(stderr,
		"\n\nShrinkler has encountered an internal error.\n"
		"Please send a bug report to blueberry@loonies.dk,\n"
		"providing the file you tried to compress.\n"
		"\n"
		"Thanks, and apologies for the inconvenience.\n\n");
	fflush(stderr);
	exit(1);
}

#ifndef NDEBUG
#include <stdio.h>
static void _assert_func(const char *file, int line, const char *exp) {
	fflush(stdout);
	fprintf(stderr, "\n\nassertion \"%s\" failed: file \"%s\", line %d\n", exp, file, line);
	fflush(stderr);
#ifdef DEBUG
	__asm volatile ("int3;");
#endif
	internal_error();
}
#undef assert
#define assert(__e) ((__e) ? (void)0 : _assert_func (__FILE__, __LINE__, #__e))
#endif

