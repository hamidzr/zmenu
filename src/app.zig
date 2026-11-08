const std = @import("std");
const objc = @import("objc");
const appconfig = @import("config.zig");
const cache = @import("cache.zig");
const callbacks = @import("app/callbacks.zig");
const chrome = @import("app/chrome.zig");
const classes = @import("app/classes.zig");
const layout = @import("layout.zig");
const logic = @import("app/logic.zig");
const placement = @import("app/placement.zig");
const objc_helpers = @import("app/objc_helpers.zig");
const state = @import("app/state.zig");
const theme = @import("app/theme.zig");
const snapshot = @import("app/snapshot.zig");
const updates = @import("app/updates.zig");
const menu = @import("menu.zig");
const pid = @import("pid.zig");
const exit_codes = @import("exit_codes.zig");
const io_compat = @import("io_compat.zig");
const time_compat = @import("time_compat.zig");

const NSPoint = objc_helpers.NSPoint;
const NSSize = objc_helpers.NSSize;
const NSRect = objc_helpers.NSRect;
const nsString = objc_helpers.nsString;
const nsColor = objc_helpers.nsColor;
const nsFont = objc_helpers.nsFont;
const nsFontWeight = objc_helpers.nsFontWeight;
const lineHeight = objc_helpers.lineHeight;
const font_weight_medium = objc_helpers.font_weight_medium;
const font_weight_regular = objc_helpers.font_weight_regular;
const applyPlaceholderColor = objc_helpers.applyPlaceholderColor;
const scheduleTimer = objc_helpers.scheduleTimer;

const startUpdateQueue = updates.startUpdateQueue;
const followStdinThread = updates.followStdinThread;

const NSApplicationActivationPolicyAccessory: i64 = 1;
const NSApplicationActivationPolicyProhibited: i64 = 2;
const NSWindowStyleMaskBorderless: u64 = 0;
const NSBackingStoreBuffered: u64 = 2;
// header views keep their distance from the top edge; the list absorbs height changes
const ns_view_min_y_margin: c_ulong = 8;
const ns_view_height_sizable: c_ulong = 16;

fn clamp(value: f64, lo: f64, hi: f64) f64 {
    return @min(@max(value, lo), hi);
}

fn activateApp(app: objc.Object) void {
    app.msgSend(void, "finishLaunching", .{});
    app.msgSend(void, "activateIgnoringOtherApps:", .{true});
    time_compat.startupStage("activation_requested");
}

fn addFixedColumn(table_view: objc.Object, identifier: [*:0]const u8, width: f64) objc.Object {
    const NSTableColumn = objc.getClass("NSTableColumn").?;
    const column = NSTableColumn.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithIdentifier:", .{nsString(identifier)});
    column.msgSend(void, "setWidth:", .{width});
    column.msgSend(void, "setMinWidth:", .{width});
    column.msgSend(void, "setMaxWidth:", .{width});
    column.msgSend(void, "setResizingMask:", .{@as(c_ulong, 0)}); // no resizing
    table_view.msgSend(void, "addTableColumn:", .{column});
    return column;
}

pub fn run(cli_config: appconfig.Config) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // dev-only offscreen render (see snapshot.zig): never activates or shows a window
    const snap = snapshot.optionsFromEnv(allocator);
    var config = cli_config;
    if (snap) |options| {
        if (options.ipc_file != null) config.ipc_only = true;
        config.auto_accept = false;
    }

    var items: []menu.MenuItem = &[_]menu.MenuItem{};
    if (!config.ipc_only and !config.follow_stdin) {
        items = menu.readItems(allocator, config.unique) catch {
            io_compat.stderrPrint("zmenu: stdin is empty\n", .{}) catch {};
            std.process.exit(exit_codes.unknown_error);
        };
    } else {
        items = allocator.alloc(menu.MenuItem, 0) catch {
            io_compat.stderrPrint("zmenu: unable to allocate items\n", .{}) catch {};
            std.process.exit(exit_codes.unknown_error);
        };
    }

    time_compat.startupStage("items_read");
    // a snapshot must not collide with a live instance of the same menu id
    const pid_path: ?[]const u8 = if (snap != null) null else pid.create(allocator, config.menu_id) catch {
        io_compat.stderrPrint("zmenu: another instance is running\n", .{}) catch {};
        std.process.exit(exit_codes.unknown_error);
    };
    defer if (pid_path) |path| pid.remove(path);

    var initial_query: []const u8 = config.initial_query;
    if (snap == null and initial_query.len == 0 and config.menu_id.len > 0) {
        if (cache.load(allocator, config.menu_id)) |cached| {
            if (cached) |cached_state| {
                if (cached_state.last_query.len > 0) {
                    initial_query = cached_state.last_query;
                }
            }
        } else |_| {}
    }

    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSApplication = objc.getClass("NSApplication").?;
    const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
    const policy = if (snap != null) NSApplicationActivationPolicyProhibited else NSApplicationActivationPolicyAccessory;
    _ = app.msgSend(bool, "setActivationPolicy:", .{policy});
    if (snap) |options| snapshot.applyAppearance(app, options);
    time_compat.startupStage("app_initialized");
    // overlap activation with view setup; auto-accept can exit without taking focus
    if (snap == null and !config.auto_accept) activateApp(app);

    const style: u64 = NSWindowStyleMaskBorderless;
    var window_width = config.window_width;
    var window_height = config.window_height;
    if (config.max_width > 0 and window_width > config.max_width) {
        window_width = config.max_width;
    }
    if (config.max_height > 0 and window_height > config.max_height) {
        window_height = config.max_height;
    }
    const field_height = config.field_height;
    const padding = config.padding;
    const list_width = window_width - (padding * 2.0);
    // the window grows and shrinks with the visible rows (logic.fitWindow); it is
    // built at the tallest size, snapped to whole rows so the bottom row is never
    // sliced mid-glyph, with `window_height` as the maximum
    const metrics = layout.Metrics.init(window_height, field_height, padding, config.row_height);
    const list_height = metrics.listHeight(metrics.max_rows);
    window_height = metrics.windowHeight(metrics.max_rows);
    const numeric_width = if (config.hasNumericSelectionColumn()) config.numeric_column_width else 0;
    const icon_width = if (config.show_icons) config.icon_column_width else 0;
    var item_width = list_width - numeric_width - icon_width;
    if (item_width < 0) item_width = 0;

    const window_rect = NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = window_width, .height = window_height },
    };

    const WindowClass = classes.windowClass();
    const window = WindowClass.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithContentRect:styleMask:backing:defer:", .{
        window_rect,
        style,
        NSBackingStoreBuffered,
        false,
    });

    if (snap == null) window.msgSend(void, "center", .{});
    window.msgSend(void, "setTitle:", .{nsString(config.title)});

    // transparent window so the vibrancy material can show through
    const NSColor = objc.getClass("NSColor").?;
    if (config.vibrancy) {
        window.msgSend(void, "setOpaque:", .{false});
        window.msgSend(void, "setBackgroundColor:", .{NSColor.msgSend(objc.Object, "clearColor", .{})});
    } else if (config.background_color) |color| {
        window.msgSend(void, "setBackgroundColor:", .{nsColor(color)});
    }

    // subtle border and rounded corners on the content layer; the content view
    // re-resolves the dynamic border color when the appearance changes
    window.msgSend(void, "setHasShadow:", .{true});
    const content_view = chrome.makeContentView(window_rect);
    window.msgSend(void, "setContentView:", .{content_view});
    content_view.msgSend(void, "setWantsLayer:", .{true});
    const layer = content_view.msgSend(objc.Object, "layer", .{});
    chrome.updateBorder(content_view);
    layer.msgSend(void, "setBorderWidth:", .{@as(f64, 1.0)});
    layer.msgSend(void, "setCornerRadius:", .{config.corner_radius});
    layer.msgSend(void, "setMasksToBounds:", .{config.corner_radius > 0.0});

    // translucent material behind the list; added first so it stays behind
    if (config.vibrancy) {
        const NSVisualEffectView = objc.getClass("NSVisualEffectView").?;
        const effect_rect = NSRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = window_width, .height = window_height },
        };
        const effect = NSVisualEffectView.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:", .{effect_rect});
        // adaptive material: HUDWindow (13) is always dark
        effect.msgSend(void, "setMaterial:", .{@as(c_long, 6)}); // NSVisualEffectMaterialPopover
        effect.msgSend(void, "setBlendingMode:", .{@as(c_long, 0)}); // NSVisualEffectBlendingModeBehindWindow
        effect.msgSend(void, "setState:", .{@as(c_long, 1)}); // NSVisualEffectStateActive
        effect.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, 18)}); // width | height
        content_view.msgSend(void, "addSubview:", .{effect});
    }

    var match_label_width: f64 = 100.0;
    var search_width: f64 = list_width - match_label_width;
    if (search_width < 0) {
        search_width = list_width;
        match_label_width = 0;
    }

    const search_font = nsFont(clamp(config.field_height * 0.48, 15.0, 21.0));
    const counter_font = objc_helpers.nsFontMonospacedDigit(clamp(config.field_height * 0.32, 12.0, 14.0), font_weight_medium);
    const palette = theme.palette(config);
    const text_color = if (config.text_color) |color| nsColor(color) else null;
    const secondary_text_color = if (config.secondary_text_color) |color| nsColor(color) else null;

    // NSTextField does not vertically centre single-line text in a taller frame, so
    // the field is sized to one line and centred; a separate rounded view provides
    // the taller visible background.
    const header_center_y = window_height - padding - field_height / 2.0;
    const search_line_height = lineHeight(search_font);
    const field_bg_rect = NSRect{
        .origin = .{ .x = padding, .y = header_center_y - field_height / 2.0 },
        .size = .{ .width = list_width, .height = field_height },
    };
    const text_inset: f64 = state.search_text_inset;
    const counter_right_inset: f64 = 12.0;
    const field_rect = NSRect{
        .origin = .{ .x = padding + text_inset, .y = header_center_y - search_line_height / 2.0 },
        .size = .{ .width = @max(search_width - text_inset * 2.0, 0.0), .height = search_line_height },
    };

    // each label is centred on its own line box; baseline-aligning the smaller
    // counter to the search baseline pushed it visibly below the field centre
    const counter_height = lineHeight(counter_font);
    const match_rect = NSRect{
        .origin = .{
            .x = padding + search_width,
            .y = header_center_y - counter_height / 2.0,
        },
        .size = .{
            .width = @max(match_label_width - counter_right_inset, 0.0),
            .height = counter_height,
        },
    };

    const list_rect = NSRect{
        .origin = .{ .x = padding, .y = padding },
        .size = .{ .width = list_width, .height = list_height },
    };

    const SearchField = classes.searchFieldClass();
    const text_field = SearchField.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{field_rect});

    text_field.msgSend(void, "setAutoresizingMask:", .{ns_view_min_y_margin});
    text_field.msgSend(void, "setEditable:", .{true});
    text_field.msgSend(void, "setSelectable:", .{true});
    // query changes filter through the delegate; only Return submits a selection
    text_field.msgSend(void, "setSendsWholeSearchString:", .{true});
    text_field.msgSend(void, "setBezeled:", .{false});
    text_field.msgSend(void, "setBordered:", .{false});
    text_field.msgSend(void, "setFocusRingType:", .{@as(c_uint, 1)}); // NSFocusRingTypeNone = 1
    text_field.msgSend(void, "setAlignment:", .{@as(c_ulong, 0)}); // NSTextAlignmentLeft

    // Ensure proper text baseline alignment
    const cell = text_field.msgSend(objc.Object, "cell", .{});
    // retain the plain input appearance inside the custom header
    cell.msgSend(void, "setSearchButtonCell:", .{@as(objc.c.id, null)});
    cell.msgSend(void, "setCancelButtonCell:", .{@as(objc.c.id, null)});
    cell.msgSend(void, "setUsesSingleLineMode:", .{true});
    cell.msgSend(void, "setLineBreakMode:", .{@as(c_ulong, 2)}); // NSLineBreakByTruncatingTail

    if (text_color) |color| {
        text_field.msgSend(void, "setTextColor:", .{color});
    }
    text_field.msgSend(void, "setFont:", .{search_font});
    text_field.msgSend(void, "setDrawsBackground:", .{false});

    // Set placeholder with custom color - must be done after setting bezeled/bordered
    if (secondary_text_color) |color| {
        applyPlaceholderColor(text_field, config.placeholder, color, search_font);
    } else {
        text_field.msgSend(void, "setPlaceholderString:", .{nsString(config.placeholder)});
    }

    const handler = classes.makeInputHandler();
    text_field.msgSend(void, "setDelegate:", .{handler});
    text_field.msgSend(void, "setTarget:", .{handler});
    text_field.msgSend(void, "setAction:", .{objc.sel("onSubmit:")});

    const NSTextField = objc.getClass("NSTextField").?;
    const match_label = NSTextField.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{match_rect});
    match_label.msgSend(void, "setAutoresizingMask:", .{ns_view_min_y_margin});
    match_label.msgSend(void, "setBezeled:", .{false});
    match_label.msgSend(void, "setDrawsBackground:", .{false});
    match_label.msgSend(void, "setEditable:", .{false});
    match_label.msgSend(void, "setSelectable:", .{false});
    match_label.msgSend(void, "setAlignment:", .{@as(c_int, 2)});
    match_label.msgSend(void, "setTextColor:", .{palette.secondary});
    match_label.msgSend(void, "setFont:", .{counter_font});

    // small spinner left of the counter while the client says more is coming
    const spinner_rect = NSRect{
        .origin = .{
            .x = padding + search_width - layout.spinner_side - 6.0,
            .y = header_center_y - layout.spinner_side / 2.0,
        },
        .size = .{ .width = layout.spinner_side, .height = layout.spinner_side },
    };
    const spinner = objc.getClass("NSProgressIndicator").?.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{spinner_rect});
    spinner.msgSend(void, "setStyle:", .{@as(c_ulong, 1)}); // NSProgressIndicatorStyleSpinning
    spinner.msgSend(void, "setControlSize:", .{@as(c_ulong, 1)}); // NSControlSizeSmall
    spinner.msgSend(void, "setIndeterminate:", .{true});
    spinner.msgSend(void, "setDisplayedWhenStopped:", .{false});
    spinner.msgSend(void, "setHidden:", .{true});
    spinner.msgSend(void, "setAutoresizingMask:", .{ns_view_min_y_margin});

    // "Loading..." / "No results" line over the empty list, pinned to the first row slot
    const message_font = nsFontWeight(clamp(config.row_height * 0.46, 13.0, 16.0), font_weight_medium);
    const message_line_height = lineHeight(message_font);
    const message_label = NSTextField.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{NSRect{
        .origin = .{
            .x = padding,
            .y = padding + list_height - config.row_height + (config.row_height - message_line_height) / 2.0 + objc_helpers.label_optical_offset,
        },
        .size = .{ .width = list_width, .height = message_line_height },
    }});
    message_label.msgSend(void, "setAutoresizingMask:", .{ns_view_min_y_margin});
    message_label.msgSend(void, "setBezeled:", .{false});
    message_label.msgSend(void, "setBordered:", .{false});
    message_label.msgSend(void, "setDrawsBackground:", .{false});
    message_label.msgSend(void, "setEditable:", .{false});
    message_label.msgSend(void, "setSelectable:", .{false});
    message_label.msgSend(void, "setAlignment:", .{@as(c_int, 1)}); // NSTextAlignmentCenter on macOS (2 is right)
    message_label.msgSend(void, "setTextColor:", .{palette.secondary});
    message_label.msgSend(void, "setFont:", .{message_font});
    message_label.msgSend(void, "setHidden:", .{true});

    const table_frame = NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = list_width, .height = list_height },
    };

    const NSTableView = objc.getClass("NSTableView").?;
    const table_view = NSTableView.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{table_frame});

    const table_font = nsFontWeight(clamp(config.row_height * 0.46, 13.0, 16.0), font_weight_medium);

    // the default (inset) style pads the rows by 5pt top and bottom, which would
    // slice the last row of a list sized to whole rows
    table_view.msgSend(void, "setStyle:", .{@as(c_long, 4)}); // NSTableViewStylePlain
    table_view.msgSend(void, "setHeaderView:", .{@as(objc.c.id, null)});
    table_view.msgSend(void, "setAllowsMultipleSelection:", .{false});
    table_view.msgSend(void, "setAllowsEmptySelection:", .{true});
    table_view.msgSend(void, "setRowHeight:", .{config.row_height});
    table_view.msgSend(void, "setUsesAlternatingRowBackgroundColors:", .{config.alternate_rows});
    table_view.msgSend(void, "setSelectionHighlightStyle:", .{@as(c_long, 0)}); // NSTableViewSelectionHighlightStyleRegular
    table_view.msgSend(void, "setTarget:", .{handler});
    // a single click accepts the row; the table never takes first responder, so the
    // search field keeps keyboard focus after any click
    table_view.msgSend(void, "setAction:", .{objc.sel("onRowClick:")});
    table_view.msgSend(void, "setRefusesFirstResponder:", .{true});
    table_view.msgSend(void, "setIntercellSpacing:", .{NSSize{ .width = 0, .height = 0 }});
    table_view.msgSend(void, "setColumnAutoresizingStyle:", .{@as(c_ulong, 1)}); // NSTableViewLastColumnOnlyAutoresizingStyle

    const NSTableColumn = objc.getClass("NSTableColumn").?;
    if (config.hasNumericSelectionColumn()) {
        _ = addFixedColumn(table_view, "index", numeric_width);
    }
    if (config.show_icons) {
        _ = addFixedColumn(table_view, "icon", icon_width);
    }
    const table_column = NSTableColumn.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithIdentifier:", .{nsString("items")});
    table_column.msgSend(void, "setWidth:", .{item_width});
    table_column.msgSend(void, "setResizingMask:", .{@as(c_ulong, 1)}); // autoresize with table
    table_view.msgSend(void, "addTableColumn:", .{table_column});

    const NSScrollView = objc.getClass("NSScrollView").?;
    const scroll_view = NSScrollView.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{list_rect});

    scroll_view.msgSend(void, "setAutoresizingMask:", .{ns_view_height_sizable});
    scroll_view.msgSend(void, "setDocumentView:", .{table_view});
    scroll_view.msgSend(void, "setHasVerticalScroller:", .{true});
    scroll_view.msgSend(void, "setAutohidesScrollers:", .{true});
    if (config.vibrancy) {
        const clear = NSColor.msgSend(objc.Object, "clearColor", .{});
        table_view.msgSend(void, "setBackgroundColor:", .{clear});
        table_view.msgSend(void, "setGridStyleMask:", .{@as(c_ulong, 0)});
        scroll_view.msgSend(void, "setDrawsBackground:", .{false});
        scroll_view.msgSend(void, "setBackgroundColor:", .{clear});
        scroll_view.msgSend(void, "setBorderType:", .{@as(c_ulong, 0)});
    } else if (config.list_background_color) |color| {
        const list_color = nsColor(color);
        table_view.msgSend(void, "setBackgroundColor:", .{list_color});
        table_view.msgSend(void, "setGridStyleMask:", .{@as(c_ulong, 0)});
        table_view.msgSend(void, "setUsesAlternatingRowBackgroundColors:", .{false});
        scroll_view.msgSend(void, "setDrawsBackground:", .{true});
        scroll_view.msgSend(void, "setBackgroundColor:", .{list_color});
        scroll_view.msgSend(void, "setBorderType:", .{@as(c_ulong, 0)});
    }
    // view-based table: tableView:viewForTableColumn:row: supplies cell views and
    // tableView:rowViewForRow: supplies ZigTableRowView, which draws selection_color.
    // A single table-wide tracking area drives the hover highlight; the owner
    // handler receives mouseMoved:/mouseExited: for the whole list.
    const NSTrackingArea = objc.getClass("NSTrackingArea").?;
    const tracking_area = NSTrackingArea.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithRect:options:owner:userInfo:", .{
        NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } },
        @as(c_ulong, 0x223), // entered|exited|moved, active in key window, in visible rect
        handler,
        @as(objc.c.id, null),
    });
    table_view.msgSend(void, "addTrackingArea:", .{tracking_area});

    // scrolling shifts rows under a stationary pointer, so re-resolve the hover row
    const NSNotificationCenter = objc.getClass("NSNotificationCenter").?;
    const notification_center = NSNotificationCenter.msgSend(objc.Object, "defaultCenter", .{});
    notification_center.msgSend(void, "addObserver:selector:name:object:", .{
        handler,
        objc.sel("scrollViewBoundsChanged:"),
        nsString("NSViewBoundsDidChangeNotification"),
        scroll_view.msgSend(objc.Object, "contentView", .{}),
    });

    content_view.msgSend(void, "addSubview:", .{scroll_view});

    // hint bar at the bottom: hidden until some listed row offers actions
    const footer_font = nsFontWeight(clamp(config.row_height * 0.34, 11.0, 12.5), font_weight_regular);
    const footer_key_font = nsFontWeight(clamp(config.row_height * 0.34, 11.0, 12.5), objc_helpers.font_weight_semibold);
    const footer_line_height = lineHeight(footer_font);
    const NSView = objc.getClass("NSView").?;
    const footer_view = NSView.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = window_width, .height = layout.footer_height },
    }});
    // stays pinned to the bottom edge when the window height changes
    footer_view.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, 2 | 32)});
    footer_view.msgSend(void, "setHidden:", .{true});
    const footer_separator = objc.getClass("NSBox").?.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{NSRect{
        .origin = .{ .x = padding, .y = layout.footer_height - 1.0 },
        .size = .{ .width = list_width, .height = 1.0 },
    }});
    footer_separator.msgSend(void, "setBoxType:", .{@as(c_ulong, 2)}); // NSBoxSeparator
    footer_view.msgSend(void, "addSubview:", .{footer_separator});
    const footer_label = NSTextField.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{NSRect{
        .origin = .{
            .x = padding + layout.footer_text_inset,
            .y = (layout.footer_height - 1.0 - footer_line_height) / 2.0 + objc_helpers.label_optical_offset,
        },
        .size = .{ .width = @max(list_width - layout.footer_text_inset * 2.0, 0.0), .height = footer_line_height },
    }});
    footer_label.msgSend(void, "setBezeled:", .{false});
    footer_label.msgSend(void, "setBordered:", .{false});
    footer_label.msgSend(void, "setDrawsBackground:", .{false});
    footer_label.msgSend(void, "setEditable:", .{false});
    footer_label.msgSend(void, "setSelectable:", .{false});
    footer_label.msgSend(void, "setAlignment:", .{@as(c_ulong, 0)});
    footer_label.msgSend(void, "setFont:", .{footer_font});
    footer_label.msgSend(void, "setTextColor:", .{palette.secondary});
    footer_view.msgSend(void, "addSubview:", .{footer_label});
    content_view.msgSend(void, "addSubview:", .{footer_view});

    const field_bg = chrome.makeFieldBackground(field_bg_rect);
    field_bg.msgSend(void, "setAutoresizingMask:", .{ns_view_min_y_margin});
    content_view.msgSend(void, "addSubview:", .{field_bg});
    content_view.msgSend(void, "addSubview:", .{message_label});
    content_view.msgSend(void, "addSubview:", .{text_field});
    if (match_label_width > 0) {
        content_view.msgSend(void, "addSubview:", .{match_label});
        content_view.msgSend(void, "addSubview:", .{spinner});
    }

    // no socket in snapshot mode: opening one would replace a live instance's
    const queue = if (snap != null) updates.QueueState{ .queue = null, .ipc_path = null } else try startUpdateQueue(config);
    time_compat.startupStage("ui_built");
    defer queue.deinit();

    var app_state = state.AppState{
        .model = try menu.Model.init(allocator, items, config.unique),
        .window = window,
        .content_view = content_view,
        .table_view = table_view,
        .text_field = text_field,
        .match_label = match_label,
        .spinner = spinner,
        .message_label = message_label,
        .scroll_view = scroll_view,
        .footer_view = footer_view,
        .footer_label = footer_label,
        .handler = handler,
        .row_font = table_font,
        .counter_font = counter_font,
        .bold_font = nsFontWeight(clamp(config.row_height * 0.46, 13.0, 16.0), objc_helpers.font_weight_bold),
        .subtitle_font = nsFontWeight(clamp(config.row_height * 0.46, 13.0, 16.0), font_weight_regular),
        .detail_font = nsFontWeight(clamp(config.row_height * 0.38, 11.0, 13.5), font_weight_regular),
        .hint_font = objc_helpers.nsFontMonospacedDigit(clamp(config.row_height * 0.36, 11.0, 13.0), font_weight_regular),
        .search_font = search_font,
        .footer_font = footer_font,
        .footer_key_font = footer_key_font,
        .palette = palette,
        .config = config,
        .metrics = metrics,
        .pid_path = pid_path,
        .allocator = allocator,
        .update_queue = queue.queue,
        .ipc_path = queue.ipc_path,
        .stream_closed = !config.follow_stdin and !config.ipc_only,
        .loaded = !config.follow_stdin and !config.ipc_only,
        .last_keystroke_ms = 0,
        .pending_stream_close_auto_accept = false,
        .had_focus = false,
        .hovered_row = null,
        .list_width = list_width,
    };
    defer app_state.model.deinit(allocator);
    state.g_state = &app_state;
    time_compat.startupStage("model_ready");

    if (queue.queue) |queue_ptr| {
        // pushes wake the main queue; this also drains anything queued during startup
        if (config.follow_stdin or config.ipc_only) {
            queue_ptr.setWake(callbacks.wakeMainThread, null);
        }
        if (config.follow_stdin and !config.ipc_only) {
            _ = std.Thread.spawn(.{}, followStdinThread, .{queue_ptr}) catch {};
        }
    }

    const data_source = classes.makeDataSource();
    table_view.msgSend(void, "setDataSource:", .{data_source});
    table_view.msgSend(void, "setDelegate:", .{data_source});

    if (config.startup_profile) {
        scheduleTimer(0.001, handler, "onStartupProfileTimer:", true);
    }

    if (config.render_bench) {
        logic.applyFilter(&app_state, "");
    } else if (initial_query.len > 0) {
        const initial_query_z = try allocator.dupeSentinel(u8, initial_query, 0);
        text_field.msgSend(void, "setStringValue:", .{nsString(initial_query_z)});
        logic.applyFilter(&app_state, initial_query);
    } else {
        logic.applyFilter(&app_state, "");
    }
    if (snap) |options| snapshot.finish(&app_state, options);
    if (config.render_bench) {
        scheduleTimer(0.2, handler, "onRenderBench:", false);
    } else {
        logic.maybeAutoAccept(&app_state, .initial);
    }

    // the initial filter already sized the window; place it from that height
    if (snap == null) placement.placeOnPointerScreen(window, metrics.windowHeightFor(metrics.max_rows, true));
    time_compat.startupStage("initial_filter");
    if (config.auto_accept) activateApp(app);
    window.msgSend(void, "setAcceptsMouseMovedEvents:", .{true});
    window.msgSend(void, "makeKeyAndOrderFront:", .{@as(objc.c.id, null)});
    if (config.render_bench) {
        io_compat.stderrPrint("render-bench launch_ms={d:.3}\n", .{time_compat.sinceProcessStartMs()}) catch {};
    }
    _ = window.msgSend(bool, "makeFirstResponder:", .{text_field});
    time_compat.startupStage("first_responder_requested");
    app.msgSend(void, "run", .{});
}
