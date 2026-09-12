// Our own glue, not upstream Shrinkler - see README.md and
// shrinkler_shim.h.
//
// Standard-library includes come first, matching the order the
// vendored headers themselves rely on but don't all declare (e.g.
// SizeMeasuringCoder.h uses floor()/log() without including <cmath>
// itself - it works in upstream's own Shrinkler.cpp only because
// RangeCoder.h, which does include <cmath>, is pulled in earlier in
// that single translation unit via Pack.h's own include order. We
// reproduce that same single-translation-unit structure here: only
// one .cpp in this whole vendor directory, so there's no risk of the
// non-inline `RangeCoder::sizetable`/`sizetable_init` definitions in
// RangeCoder.h being defined twice at link time.
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <vector>
#include <algorithm>

#include "Pack.h"          // RangeCoder, MatchFinder, LZEncoder, LZParser, packData
#include "RangeDecoder.h"
#include "LZDecoder.h"

#include "shrinkler_shim.h"

namespace {

// Reconstructs decompressed bytes into a fixed-size caller buffer, for
// shrinkler_decompress_buffer's round-trip test - the same role
// zx0_vendor's/salvador_vendor's own vendored decompressors play, but
// written here rather than vendored: Shrinkler's own Verifier.h
// (LZVerifier) checks a decode against already-known-correct data
// rather than reconstructing standalone output, so it doesn't fit our
// "decompress into a buffer, then compare" test shape without this
// small adapter.
class BufferReceiver : public LZReceiver {
    unsigned char *out;
    size_t capacity;
    size_t pos;
    bool overflowed;

public:
    BufferReceiver(unsigned char *out, size_t capacity)
        : out(out), capacity(capacity), pos(0), overflowed(false) {}

    bool receiveLiteral(unsigned char value) override {
        if (pos >= capacity) {
            overflowed = true;
            return false;
        }
        out[pos++] = value;
        return true;
    }

    bool receiveReference(int offset, int length) override {
        if (offset < 1 || (size_t)offset > pos || length < 0) {
            overflowed = true;
            return false;
        }
        for (int i = 0; i < length; i++) {
            if (pos >= capacity) {
                overflowed = true;
                return false;
            }
            out[pos] = out[pos - (size_t)offset];
            pos++;
        }
        return true;
    }

    size_t size() const { return pos; }
    bool failed() const { return overflowed; }
};

// execram bakes in one fixed choice for both parameters that must
// agree between host encoder and 68k depacker (see shrinkler_shim.h):
// parity context on (Shrinkler's own --data default), and the "-3"
// preset Shrinkler itself defaults to when no digit flag is given.
constexpr bool kParityContext = true;

PackParams defaultParams() {
    PackParams params;
    params.parity_context = kParityContext;
    params.iterations = 3;
    params.length_margin = 3;
    params.skip_length = 3000;
    params.match_patience = 300;
    params.max_same_length = 30;
    return params;
}

} // namespace

int shrinkler_compress_buffer(
    const unsigned char *data,
    size_t data_len,
    unsigned char **out_data,
    size_t *out_len
) {
    if (data_len == 0) {
        // MatchFinder/SuffixArray assume at least one byte (they build
        // a sentinel-terminated suffix array over `length + 1`
        // elements starting from the real data) - execram's own
        // flatten.zig never produces a zero-length payload (there's
        // always at least the reloc-stream terminator byte), but guard
        // it explicitly rather than letting SuffixArray's internal
        // assert() fire.
        return 1;
    }

    PackParams params = defaultParams();
    RefEdgeFactory edge_factory(100000); // Shrinkler CLI's own default -r

    // Upstream's own DataFile.h always sizes the context array as
    // LZEncoder::NUM_CONTEXTS + NUM_RELOC_CONTEXTS (256 more, defined
    // in HunkFile.h, not vendored here - see README.md), even in
    // --data mode where no relocation contexts are ever addressed, so
    // one decompressor context-table size serves both its hunk and
    // data modes. We only ever emit LZEncoder's own context indices
    // (never relocation-context ones), and each context's adaptive
    // probability evolves independently of how many other unused slots
    // exist in the array, so sizing the array to exactly
    // LZEncoder::NUM_CONTEXTS produces bit-for-bit identical output to
    // sizing it larger - it just skips allocating/initializing 256
    // slots nothing ever reads. stubs/shrinkler's own context table is
    // already sized 1536 (comfortably more than either number), so
    // this doesn't need to match anything on the depacker side either.
    std::vector<unsigned char> pack_buffer;
    RangeCoder range_coder(LZEncoder::NUM_CONTEXTS, pack_buffer);
    range_coder.reset();
    packData(const_cast<unsigned char *>(data), (int)data_len, 0, &params, &range_coder, &edge_factory, false);
    range_coder.finish();

    unsigned char *buf = (unsigned char *)malloc(pack_buffer.size());
    if (buf == nullptr) return 1;
    std::copy(pack_buffer.begin(), pack_buffer.end(), buf);

    *out_data = buf;
    *out_len = pack_buffer.size();
    return 0;
}

void shrinkler_free_buffer(unsigned char *data) {
    free(data);
}

size_t shrinkler_decompress_buffer(
    const unsigned char *data,
    size_t data_len,
    unsigned char *out,
    size_t out_capacity
) {
    // Must match shrinkler_compress_buffer's own context-array size
    // exactly (see the comment there) - not because the *count* itself
    // is bit-significant, but because both sides must at least agree
    // on which index range LZEncoder's context IDs fall into, which a
    // smaller-or-equal array on this side would still satisfy, but
    // there's no reason to size it differently.
    std::vector<unsigned char> in(data, data + data_len);
    RangeDecoder decoder(LZEncoder::NUM_CONTEXTS, in);
    LZDecoder lzd(&decoder, kParityContext);

    BufferReceiver receiver(out, out_capacity);
    decoder.reset();
    if (!lzd.decode(receiver) || receiver.failed()) {
        return (size_t)-1;
    }
    return receiver.size();
}
