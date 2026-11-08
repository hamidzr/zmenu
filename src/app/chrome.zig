//! Custom NSView subclasses that draw with dynamic colors, so they follow
//! Light/Dark switches without re-applying any CGColor.

const objc = @import("objc");
const objc_helpers = @import("objc_helpers.zig");
const state = @import("state.zig");

const NSRect = objc_helpers.NSRect;

/// Re-resolves the dynamic separator color for the current appearance and
/// applies it to the content layer border (layers only take CGColors).
pub fn updateBorder(view: objc.Object) void {
    const layer = view.msgSend(objc.Object, "layer", .{});
    if (layer.value == null) return;
    const NSAppearance = objc.getClass("NSAppearance").?;
    const NSColor = objc.getClass("NSColor").?;
    const previous = NSAppearance.msgSend(objc.Object, "currentAppearance", .{});
    NSAppearance.msgSend(void, "setCurrentAppearance:", .{view.msgSend(objc.Object, "effectiveAppearance", .{})});
    const color = NSColor.msgSend(objc.Object, "separatorColor", .{});
    layer.msgSend(void, "setBorderColor:", .{color.msgSend(objc.c.id, "CGColor", .{})});
    NSAppearance.msgSend(void, "setCurrentAppearance:", .{previous});
}

fn viewDidChangeEffectiveAppearance(target: objc.c.id, sel: objc.c.SEL) callconv(.c) void {
    _ = sel;
    if (target == null) return;
    const view = objc.Object.fromId(target);
    const NSView = objc.getClass("NSView").?;
    view.msgSendSuper(NSView, void, "viewDidChangeEffectiveAppearance", .{});
    updateBorder(view);
}

fn contentViewClass() objc.Class {
    if (objc.getClass("ZigContentView")) |cls| return cls;
    const NSView = objc.getClass("NSView").?;
    const cls = objc.allocateClassPair(NSView, "ZigContentView").?;
    if (!cls.addMethod("viewDidChangeEffectiveAppearance", viewDidChangeEffectiveAppearance)) {
        @panic("failed to add viewDidChangeEffectiveAppearance method");
    }
    objc.registerClassPair(cls);
    return cls;
}

pub fn makeContentView(frame: NSRect) objc.Object {
    return contentViewClass().msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{frame});
}

fn fieldBackgroundDrawRect(target: objc.c.id, sel: objc.c.SEL, dirty_rect: NSRect) callconv(.c) void {
    _ = sel;
    _ = dirty_rect;
    if (target == null) return;
    const app_state = state.g_state orelse return;
    const bounds = objc.Object.fromId(target).msgSend(NSRect, "bounds", .{});
    app_state.palette.field_fill.msgSend(void, "setFill", .{});
    const NSBezierPath = objc.getClass("NSBezierPath").?;
    const radius: f64 = 8.0;
    const path = NSBezierPath.msgSend(objc.Object, "bezierPathWithRoundedRect:xRadius:yRadius:", .{ bounds, radius, radius });
    path.msgSend(void, "fill", .{});
}

fn fieldBackgroundClass() objc.Class {
    if (objc.getClass("ZigFieldBackground")) |cls| return cls;
    const NSView = objc.getClass("NSView").?;
    const cls = objc.allocateClassPair(NSView, "ZigFieldBackground").?;
    if (!cls.addMethod("drawRect:", fieldBackgroundDrawRect)) @panic("failed to add drawRect: method");
    objc.registerClassPair(cls);
    return cls;
}

/// the rounded fill behind the search field, drawn with `Palette.field_fill`
pub fn makeFieldBackground(frame: NSRect) objc.Object {
    return fieldBackgroundClass().msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{frame});
}
