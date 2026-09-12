// Copyright 1999-2022 Aske Simon Christensen. See LICENSE.txt for usage terms.

/*

Pack a data block in multiple iterations, reporting progress along the way.

*/

// Vendored for execram from askeksa/Shrinkler - see
// shrinkler_vendor/README.md for the exact commit. One deliberate
// change from upstream: packData()'s two unconditional `printf` calls
// (the running data-length/per-pass-size status line, printed
// regardless of the `show_progress` argument - that argument only
// gates the PackProgress vs. NoProgress choice, a separate thing) are
// removed. They wrote raw text directly to stdout, which is also the
// channel `zig build test` uses to talk to the test binary over
// Zig's `--listen=-` protocol - those stray bytes corrupted that
// protocol and hung the test runner (same bug class already hit and
// fixed once in this project - see
// src/backends/zx0_vendor/optimize.c's own comment on the identical
// symptom, confirmed the same way: sampling both processes' stacks
// mid-hang showed each blocked waiting on a message the other would
// never send, both idle rather than spinning).

#pragma once

#include "RangeCoder.h"
#include "MatchFinder.h"
#include "CountingCoder.h"
#include "SizeMeasuringCoder.h"
#include "LZEncoder.h"
#include "LZParser.h"

struct PackParams {
	bool parity_context;

	int iterations;
	int length_margin;
	int skip_length;
	int match_patience;
	int max_same_length;
};

class PackProgress : public LZProgress {
	int size;
	int steps;
	int next_step_threshold;
	int textlength;

	void print() {
		textlength = printf("[%d.%d%%]", steps / 10, steps % 10);
		fflush(stdout);
	}

	void rewind() {
		printf("\033[%dD", textlength);
	}
public:
	virtual void begin(int size) {
		this->size = size;
		steps = 0;
		next_step_threshold = size / 1000;
		print();
	}

	virtual void update(int pos) {
		if (pos < next_step_threshold) return;
		while (pos >= next_step_threshold) {
			steps += 1;
			next_step_threshold = (long long) size * (steps + 1) / 1000;
		}
		rewind();
		print();
	}

	virtual void end() {
		rewind();
		printf("\033[K");
		fflush(stdout);
	}
};

class NoProgress : public LZProgress {
public:
	virtual void begin(int size) {
		fflush(stdout);
	}

	virtual void update(int pos) {
	}

	virtual void end() {
	}
};

void packData(unsigned char *data, int data_length, int zero_padding, PackParams *params, Coder *result_coder, RefEdgeFactory *edge_factory, bool show_progress) {
	MatchFinder finder(data, data_length, 2, params->match_patience, params->max_same_length);
	LZParser parser(data, data_length, zero_padding, finder, params->length_margin, params->skip_length, edge_factory);
	result_size_t real_size = 0;
	result_size_t best_size = (result_size_t)1 << (32 + 3 + Coder::BIT_PRECISION);
	int best_result = 0;
	vector<LZParseResult> results(2);
	CountingCoder *counting_coder = new CountingCoder(LZEncoder::NUM_CONTEXTS);
	LZProgress *progress;
	if (show_progress) {
		progress = new PackProgress();
	} else {
		progress = new NoProgress();
	}
	for (int i = 0 ; i < params->iterations ; i++) {
		// Parse data into LZ symbols
		LZParseResult& result = results[1 - best_result];
		Coder *measurer = new SizeMeasuringCoder(counting_coder);
		measurer->setNumberContexts(LZEncoder::NUMBER_CONTEXT_OFFSET, LZEncoder::NUM_NUMBER_CONTEXTS, data_length);
		finder.reset();
		result = parser.parse(LZEncoder(measurer, params->parity_context), progress);
		delete measurer;

		// Encode result using adaptive range coding
		vector<unsigned char> dummy_result;
		RangeCoder *range_coder = new RangeCoder(LZEncoder::NUM_CONTEXTS, dummy_result);
		real_size = result.encode(LZEncoder(range_coder, params->parity_context));
		range_coder->finish();
		delete range_coder;

		// Choose if best
		if (real_size < best_size) {
			best_result = 1 - best_result;
			best_size = real_size;
		}

		// Count symbol frequencies
		CountingCoder *new_counting_coder = new CountingCoder(LZEncoder::NUM_CONTEXTS);
		result.encode(LZEncoder(counting_coder, params->parity_context));
	
		// New size measurer based on frequencies
		CountingCoder *old_counting_coder = counting_coder;
		counting_coder = new CountingCoder(old_counting_coder, new_counting_coder);
		delete old_counting_coder;
		delete new_counting_coder;
	}
	delete progress;
	delete counting_coder;

	results[best_result].encode(LZEncoder(result_coder, params->parity_context));
}
