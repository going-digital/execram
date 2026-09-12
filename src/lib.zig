//! Re-exports the pieces of execram's own implementation that
//! tools/bench needs (container-header parsing, every backend's
//! host-side `decompress`, the shared Musashi-driving core), as a
//! single named module (`build.zig` wires it in as `bench_module`'s
//! `"execram_lib"` import).
//!
//! Not used by `execram` itself for most of these - main.zig imports
//! most of these files directly, since it's already rooted inside
//! `src/` and can reach them with a plain relative `@import`.
//! tools/bench/main.zig can't do the same: Zig's module system resolves
//! a relative `@import` against the importing module's own root
//! directory (here, `tools/bench/`) and refuses one that would resolve
//! outside it - `@import("../../src/hunk.zig")` tried exactly that and
//! failed with "import of file outside module path". Routing through
//! one small facade file that *is* inside `src/` sidesteps this: every
//! name below is a same-module, in-tree relative import from
//! `src/lib.zig`'s own perspective, exactly like main.zig's.
//! (`musashi_bench.zig` is the one exception to "main.zig imports it
//! directly" - `execram bench` does exactly that too, since it's a
//! plain file in `src/`.)

pub const hunk = @import("hunk.zig");
pub const info = @import("info.zig");
pub const container = @import("container.zig");
pub const store = @import("backends/store.zig");
pub const inflate = @import("backends/inflate.zig");
pub const zx0 = @import("backends/zx0.zig");
pub const shrinkler = @import("backends/shrinkler.zig");
pub const musashi_bench = @import("musashi_bench.zig");
