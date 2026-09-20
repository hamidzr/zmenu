const std = @import("std");
const objc = @import("objc");
const appconfig = @import("../config.zig");
const io_compat = @import("../io_compat.zig");

pub const NSPoint = extern struct {
    x: f64,
    y: f64,
};

pub const NSSize = extern struct {
    width: f64,
    height: f64,
};

pub const NSRect = extern struct {
    origin: NSPoint,
    size: NSSize,
};

pub fn nsString(str: [*:0]const u8) objc.Object {
    const NSString = objc.getClass("NSString").?;
    return NSString.msgSend(objc.Object, "stringWithUTF8String:", .{str});
}

pub fn nsColor(color: appconfig.Color) objc.Object {
    const NSColor = objc.getClass("NSColor").?;
    return NSColor.msgSend(objc.Object, "colorWithSRGBRed:green:blue:alpha:", .{
        color.r,
        color.g,
        color.b,
        color.a,
    });
}

pub fn nsFont(size: f64) objc.Object {
    const NSFont = objc.getClass("NSFont").?;
    return NSFont.msgSend(objc.Object, "systemFontOfSize:", .{size});
}

pub fn applyPlaceholderColor(field: objc.Object, placeholder: [*:0]const u8, color: objc.Object) void {
    const NSDictionary = objc.getClass("NSDictionary").?;
    const NSAttributedString = objc.getClass("NSAttributedString").?;
    const key = nsString("NSColor");
    const value = NSDictionary.msgSend(objc.Object, "dictionaryWithObject:forKey:", .{ color, key });
    const attributed = NSAttributedString.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithString:attributes:", .{ nsString(placeholder), value });
    field.msgSend(void, "setPlaceholderAttributedString:", .{attributed});
}

pub fn columnIsIndex(column: objc.Object) bool {
    const identifier = column.msgSend(objc.Object, "identifier", .{});
    const utf8_ptr = identifier.msgSend(?[*:0]const u8, "UTF8String", .{});
    if (utf8_ptr == null) return false;
    const name = std.mem.sliceTo(utf8_ptr.?, 0);
    return std.mem.eql(u8, name, "index");
}

pub fn columnIsIcon(column: objc.Object) bool {
    const identifier = column.msgSend(objc.Object, "identifier", .{});
    const utf8_ptr = identifier.msgSend(?[*:0]const u8, "UTF8String", .{});
    if (utf8_ptr == null) return false;
    const name = std.mem.sliceTo(utf8_ptr.?, 0);
    return std.mem.eql(u8, name, "icon");
}

var icon_cache: std.StringHashMapUnmanaged(?objc.Object) = .{};

/// Loads and retains the workspace icon for an absolute path, resized once
/// to the row size so per-draw scaling disappears. Missing and invalid paths
/// are cached as blank to avoid repeated filesystem checks.
pub fn iconImage(path: ?[:0]const u8, side: f64) ?objc.Object {
    const icon_path = path orelse return null;
    if (icon_path.len == 0 or !std.fs.path.isAbsolute(icon_path)) return null;
    if (icon_cache.get(icon_path)) |cached| return cached;

    const image = loadIconImage(icon_path, side);
    const key = std.heap.c_allocator.dupe(u8, icon_path) catch return image;
    icon_cache.put(std.heap.c_allocator, key, image) catch {
        std.heap.c_allocator.free(key);
        return image;
    };
    return image;
}

fn loadIconImage(path: [:0]const u8, side: f64) ?objc.Object {
    io_compat.accessAbsolute(path, .{}) catch return null;

    const NSWorkspace = objc.getClass("NSWorkspace").?;
    const workspace = NSWorkspace.msgSend(objc.Object, "sharedWorkspace", .{});
    const image = workspace.msgSend(objc.Object, "iconForFile:", .{nsString(path.ptr)});
    if (image.value == null) return null;
    const side_len = @max(side, 1.0);
    image.msgSend(void, "setSize:", .{NSSize{ .width = side_len, .height = side_len }});
    return image.retain();
}
