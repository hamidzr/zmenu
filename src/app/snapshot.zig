//! Dev-only offscreen snapshot mode (`just snapshot`). With `ZMENU_SNAPSHOT=<out.png>`
//! the normal window and views are built but never shown or activated: the
//! activation policy is Prohibited, the window is never ordered in, no socket
//! or pid file is created. The content is laid out, drawn into a bitmap and
//! written as a PNG, then the process exits 0. It never takes focus, so it is
//! safe to run while working in other windows.
//!
//! Optional env:
//!   ZMENU_SNAPSHOT_IPC=<file>          one IPC JSON message (no length header),
//!                                      applied as if received over the socket
//!   ZMENU_SNAPSHOT_SELECT=<n>          move the selection n rows down as a user move
//!   ZMENU_SNAPSHOT_APPEARANCE=light|dark  force the app appearance
//!   ZMENU_SNAPSHOT_ACTIONS=1           open the Cmd+K action panel for the selected row
//!   ZMENU_SNAPSHOT_ACTIONS_SELECT=<n>  select panel row n (0 is the primary action)
//!   ZMENU_SNAPSHOT_CONFIRM=<mods|1>    accept with those mods (canonical "alt", "shift+cmd";
//!                                      1 = plain Enter) to show the confirm prompt; the
//!                                      accept must need confirming, else it prints and exits
//!
//! Vibrancy (NSVisualEffectView) renders empty offscreen, so a solid approximation
//! of the material is painted behind the content.

const std = @import("std");
const objc = @import("objc");
const callbacks = @import("callbacks.zig");
const logic = @import("logic.zig");
const mods_mod = @import("../mods.zig");
const objc_helpers = @import("objc_helpers.zig");
const state = @import("state.zig");
const updates = @import("updates.zig");
const io_compat = @import("../io_compat.zig");

const NSRect = objc_helpers.NSRect;
const nsString = objc_helpers.nsString;
const nsColor = objc_helpers.nsColor;

pub const Appearance = enum { light, dark };

pub const Options = struct {
    out_path: [:0]const u8,
    ipc_file: ?[:0]const u8,
    select: usize,
    appearance: ?Appearance,
    actions: bool,
    actions_select: usize,
    confirm: ?[:0]const u8,
};

fn envOptional(allocator: std.mem.Allocator, name: []const u8) ?[:0]const u8 {
    const value = io_compat.getEnvVarOwnedOptional(allocator, name) catch return null;
    const text = value orelse return null;
    if (text.len == 0) return null;
    return allocator.dupeSentinel(u8, text, 0) catch null;
}

pub fn optionsFromEnv(allocator: std.mem.Allocator) ?Options {
    const out_path = envOptional(allocator, "ZMENU_SNAPSHOT") orelse return null;
    var select: usize = 0;
    if (envOptional(allocator, "ZMENU_SNAPSHOT_SELECT")) |text| {
        select = std.fmt.parseInt(usize, text, 10) catch 0;
    }
    var appearance: ?Appearance = null;
    if (envOptional(allocator, "ZMENU_SNAPSHOT_APPEARANCE")) |text| {
        appearance = std.meta.stringToEnum(Appearance, text);
    }
    var actions_select: usize = 0;
    if (envOptional(allocator, "ZMENU_SNAPSHOT_ACTIONS_SELECT")) |text| {
        actions_select = std.fmt.parseInt(usize, text, 10) catch 0;
    }
    return .{
        .out_path = out_path,
        .ipc_file = envOptional(allocator, "ZMENU_SNAPSHOT_IPC"),
        .select = select,
        .appearance = appearance,
        .actions = envOptional(allocator, "ZMENU_SNAPSHOT_ACTIONS") != null,
        .actions_select = actions_select,
        .confirm = envOptional(allocator, "ZMENU_SNAPSHOT_CONFIRM"),
    };
}

pub fn applyAppearance(app: objc.Object, options: Options) void {
    const appearance = options.appearance orelse return;
    const name = switch (appearance) {
        .light => "NSAppearanceNameAqua",
        .dark => "NSAppearanceNameDarkAqua",
    };
    const NSAppearance = objc.getClass("NSAppearance").?;
    const value = NSAppearance.msgSend(objc.Object, "appearanceNamed:", .{nsString(name)});
    app.msgSend(void, "setAppearance:", .{value});
}

fn fail(comptime message: []const u8, args: anytype) noreturn {
    io_compat.stderrPrint("zmenu snapshot: " ++ message ++ "\n", args) catch {};
    std.process.exit(1);
}

fn applyIpcFile(app_state: *state.AppState, path: [:0]const u8) void {
    const file = std.Io.Dir.cwd().openFile(io_compat.globalIo(), path, .{}) catch fail("cannot open {s}", .{path});
    defer io_compat.closeFile(file);
    const payload = io_compat.readAllFile(std.heap.c_allocator, file, 1024 * 1024) catch fail("cannot read {s}", .{path});
    defer std.heap.c_allocator.free(payload);

    const queue = std.heap.c_allocator.create(updates.UpdateQueue) catch fail("out of memory", .{});
    queue.* = updates.UpdateQueue.init(std.heap.c_allocator);
    app_state.update_queue = queue;
    updates.handleIpcPayload(queue, payload);
    callbacks.drainUpdates();
}

fn appearanceIsDark(view: objc.Object) bool {
    const appearance = view.msgSend(objc.Object, "effectiveAppearance", .{});
    const name = appearance.msgSend(objc.Object, "name", .{});
    const utf8 = name.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return true;
    return std.mem.indexOf(u8, std.mem.sliceTo(utf8, 0), "Dark") != null;
}

fn backdropDrawRect(target: objc.c.id, sel: objc.c.SEL, dirty_rect: NSRect) callconv(.c) void {
    _ = sel;
    _ = dirty_rect;
    if (target == null) return;
    const view = objc.Object.fromId(target);
    const bounds = view.msgSend(NSRect, "bounds", .{});
    const color = if (appearanceIsDark(view))
        nsColor(.{ .r = 0.118, .g = 0.118, .b = 0.118, .a = 0.95 })
    else
        nsColor(.{ .r = 0.949, .g = 0.949, .b = 0.949, .a = 1.0 });
    const radius = if (state.g_state) |app_state| app_state.config.corner_radius else 0.0;
    color.msgSend(void, "setFill", .{});
    const NSBezierPath = objc.getClass("NSBezierPath").?;
    const path = NSBezierPath.msgSend(objc.Object, "bezierPathWithRoundedRect:xRadius:yRadius:", .{ bounds, radius, radius });
    path.msgSend(void, "fill", .{});
}

fn backdropClass() objc.Class {
    if (objc.getClass("ZigSnapshotBackdrop")) |cls| return cls;
    const NSView = objc.getClass("NSView").?;
    const cls = objc.allocateClassPair(NSView, "ZigSnapshotBackdrop").?;
    if (!cls.addMethod("drawRect:", backdropDrawRect)) @panic("failed to add drawRect: method");
    objc.registerClassPair(cls);
    return cls;
}

/// puts the solid stand-in for the vibrancy material below every other subview
fn addBackdrop(app_state: *state.AppState) void {
    const bounds = app_state.content_view.msgSend(NSRect, "bounds", .{});
    const backdrop = backdropClass().msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{bounds});
    backdrop.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, 18)}); // width | height
    const NSWindowBelow: c_long = -1;
    app_state.content_view.msgSend(void, "addSubview:positioned:relativeTo:", .{
        backdrop,
        NSWindowBelow,
        @as(objc.c.id, null),
    });
}

/// Renders the window and exits; never returns.
pub fn finish(app_state: *state.AppState, options: Options) noreturn {
    if (options.ipc_file) |path| applyIpcFile(app_state, path);
    if (options.select > 0) logic.moveSelectionClamped(app_state, @intCast(options.select));
    if (options.actions) {
        logic.openPanel(app_state);
        if (!logic.panelOpen(app_state)) fail("the selected row has no actions", .{});
        if (options.actions_select > 0) logic.moveSelectionClamped(app_state, @intCast(options.actions_select));
    }
    if (options.confirm) |text| {
        const held: mods_mod.Mods = if (std.mem.eql(u8, text, "1")) .{} else mods_mod.Mods.parse(text) orelse fail("bad mods {s}", .{text});
        logic.acceptWith(app_state, held);
        if (!app_state.confirm.isPending()) fail("nothing is pending after the accept", .{});
    }
    addBackdrop(app_state);

    const content_view = app_state.content_view;
    content_view.msgSend(void, "layoutSubtreeIfNeeded", .{});
    app_state.table_view.msgSend(void, "reloadData", .{});
    logic.updateSelection(app_state);
    content_view.msgSend(void, "layoutSubtreeIfNeeded", .{});
    content_view.msgSend(void, "displayIfNeeded", .{});

    // the frame view also covers the rounded corners and window background
    const root = content_view.msgSend(objc.Object, "superview", .{});
    const target = if (root.value != null) root else content_view;
    const bounds = target.msgSend(NSRect, "bounds", .{});
    const rep = target.msgSend(objc.Object, "bitmapImageRepForCachingDisplayInRect:", .{bounds});
    if (rep.value == null) fail("no bitmap for {d}x{d} view", .{ bounds.size.width, bounds.size.height });
    target.msgSend(void, "cacheDisplayInRect:toBitmapImageRep:", .{ bounds, rep });

    const NSBitmapImageFileTypePNG: c_ulong = 4;
    const NSDictionary = objc.getClass("NSDictionary").?;
    const properties = NSDictionary.msgSend(objc.Object, "dictionary", .{});
    const data = rep.msgSend(objc.Object, "representationUsingType:properties:", .{ NSBitmapImageFileTypePNG, properties });
    if (data.value == null) fail("PNG encoding failed", .{});
    if (!data.msgSend(bool, "writeToFile:atomically:", .{ nsString(options.out_path.ptr), true })) {
        fail("cannot write {s}", .{options.out_path});
    }
    std.process.exit(0);
}
