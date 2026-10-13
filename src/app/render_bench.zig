const std = @import("std");
const objc = @import("objc");
const io_compat = @import("../io_compat.zig");
const time_compat = @import("../time_compat.zig");
const objc_helpers = @import("objc_helpers.zig");
const logic = @import("logic.zig");
const state = @import("state.zig");

const nsString = objc_helpers.nsString;

const render_bench_warmup: usize = 5;
const render_bench_rounds: usize = 8;
const render_bench_max_samples: usize = 128;

/// Dev-only end-to-end bench: type the first item's label one character at a
/// time (filter + reload + paint per keystroke), then accept it and exit.
/// Prints per-keystroke timing stats and total time since process start.
pub fn onRenderBench(target: objc.c.id, sel: objc.c.SEL, timer: objc.c.id) callconv(.c) void {
    _ = target;
    _ = sel;
    _ = timer;

    const app_state = state.g_state orelse return;
    if (app_state.model.filtered.items.len == 0) {
        io_compat.stderrPrint("render-bench: no items\n", .{}) catch {};
        logic.quit(app_state, 1);
    }

    const label = app_state.model.items[app_state.model.filtered.items[0]].label;
    const query_len = @min(label.len, render_bench_max_samples);

    var w: usize = 0;
    while (w < render_bench_warmup) : (w += 1) {
        applyQuery(app_state, "");
        benchPaint(app_state);
    }

    var keystroke_samples: [render_bench_max_samples * render_bench_rounds]i128 = undefined;
    var paint_samples: [render_bench_max_samples * render_bench_rounds]i128 = undefined;
    var sample_count: usize = 0;

    var round: usize = 0;
    while (round < render_bench_rounds) : (round += 1) {
        var len: usize = 1;
        while (len <= query_len) : (len += 1) {
            const query = label[0..len];
            const start = time_compat.monotonicNs();
            applyQuery(app_state, query);
            const after_filter = time_compat.monotonicNs();
            benchPaint(app_state);
            const after_paint = time_compat.monotonicNs();
            keystroke_samples[sample_count] = after_paint - start;
            paint_samples[sample_count] = after_paint - after_filter;
            sample_count += 1;
        }
    }

    const keystroke = summarize(keystroke_samples[0..sample_count]);
    const paint = summarize(paint_samples[0..sample_count]);
    const matched = app_state.model.filtered.items.len;
    const selected = app_state.model.selectedItem() != null;

    io_compat.stderrPrint(
        "render-bench items={d} rounds={d} samples={d} keystroke_median={d:.3}ms keystroke_max={d:.3}ms paint_median={d:.3}ms total_ms={d:.3}\n",
        .{
            app_state.model.items.len,
            render_bench_rounds,
            sample_count,
            keystroke.median,
            keystroke.max,
            paint.median,
            time_compat.sinceProcessStartMs(),
        },
    ) catch {};
    io_compat.stderrPrint("render-bench matched={d} selected_ok={} label={s}\n", .{ matched, selected, label }) catch {};

    // finish the flow like a user pressing Enter
    logic.acceptSelection(app_state);
    logic.quit(app_state, 0);
}

fn applyQuery(app_state: *state.AppState, query: []const u8) void {
    var buf: [render_bench_max_samples + 1]u8 = undefined;
    if (query.len >= buf.len) return;
    @memcpy(buf[0..query.len], query);
    buf[query.len] = 0;
    const query_z: [:0]u8 = buf[0..query.len :0];
    app_state.text_field.msgSend(void, "setStringValue:", .{nsString(query_z.ptr)});
    logic.applyFilter(app_state, query);
}

fn benchPaint(app_state: *state.AppState) void {
    app_state.table_view.msgSend(void, "setNeedsDisplay:", .{true});
    app_state.content_view.msgSend(void, "layoutSubtreeIfNeeded", .{});
    app_state.content_view.msgSend(void, "displayIfNeeded", .{});
    // layer-backed views defer drawing to the Core Animation commit; flush it
    // synchronously so the measurement includes the real paint work
    const CATransaction = objc.getClass("CATransaction").?;
    CATransaction.msgSend(void, "flush", .{});
}

const BenchStats = struct {
    median: f64,
    max: f64,
};

fn summarize(samples: []i128) BenchStats {
    std.mem.sort(i128, samples, {}, std.sort.asc(i128));
    return .{
        .median = nsToMs(samples[samples.len / 2]),
        .max = nsToMs(samples[samples.len - 1]),
    };
}

fn nsToMs(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}
