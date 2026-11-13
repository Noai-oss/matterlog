const std = @import("std");
const dvui = @import("dvui");
const database = @import("database.zig");
const state = @import("app_state.zig");
const text_editor = @import("text_editor.zig");
const user_text = @import("user_text.zig");
const theme = @import("theme.zig");
const zoom_controls = @import("zoom_controls.zig");
const submit_key = if (@import("builtin").os.tag == .macos) "Cmd+Enter" else "Ctrl+Enter";

const AppState = state.AppState;
const TaskFilter = state.TaskFilter;
const header_action_button_width: f32 = 72;
const header_secondary_button_width: f32 = 40;
const sidebar_padding: f32 = 10;
const detail_padding: f32 = 12;

const HeaderControlPosition = enum { middle, trailing };

pub fn draw(app: *AppState) void {
    zoom_controls.process(&app.zoom_percent);
    var root = dvui.box(
        @src(),
        .{ .dir = .vertical },
        .{
            .expand = .both,
            .style = .window,
            .background = true,
        },
    );
    defer root.deinit();

    processEscapeShortcut(app, root.data());
    drawMainPanes(app);
    var footer = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer footer.deinit();
    if (app.sidebar_ratio == 0) drawExpandButton(app, "展开事项栏");
    zoom_controls.draw(&app.zoom_percent);
    if (app.sidebar_ratio == 1) drawExpandButton(app, "展开进展区");
}

fn drawExpandButton(app: *AppState, label: []const u8) void {
    if (dvui.button(@src(), label, .{}, .{
        .font = dvui.Font.theme(.body).withSize(10),
        .padding = .{ .x = 6, .w = 6, .y = 3, .h = 3 },
        .gravity_y = 0.5,
        .tab_index = 0,
        .tag = if (@import("builtin").is_test) "expand-pane" else null,
    })) {
        app.sidebar_ratio = app.expanded_sidebar_ratio;
        dvui.refresh(null, @src(), null);
    }
}

fn processEscapeShortcut(app: *AppState, root_data: *dvui.WidgetData) void {
    if (!app.hasActiveMode() or app.sidebar_ratio == 1) return;
    if (app.edit_history.composing or app.rename_history.composing) return;

    for (dvui.events()) |*event| {
        if (event.handled or event.evt != .key) continue;

        const key = event.evt.key;
        if (key.action != .down or key.code != .escape) continue;

        event.handle(@src(), root_data);
        app.cancelMode();
        dvui.refresh(null, @src(), root_data.id);
        return;
    }
}

fn drawMainPanes(app: *AppState) void {
    var ratio = app.sidebar_ratio;
    var panes: dvui.PanedWidget = undefined;
    panes.init(
        @src(),
        .{
            .direction = .horizontal,
            .collapsed_size = 0,
            .split_ratio = &ratio,
            // Keep the handle width stable while hovering to prevent jitter.
            .handle_size = 6,
            .handle_margin = 2,
        },
        .{ .expand = .both, .background = false },
    );
    defer panes.deinit();

    const available = @max(1, panes.data().contentRect().w - 2 * panes.handleSize());
    const limits = paneRatioLimits(available);
    if (ratio > 0 and ratio < 1) ratio = std.math.clamp(ratio, limits.min, limits.max);
    const before = ratio;
    const was_dragging = dvui.captured(panes.data().id);
    panes.processEvents();
    if (!was_dragging and before > 0 and before < 1 and
        (dvui.captured(panes.data().id) or ratio != before))
        app.expanded_sidebar_ratio = app.sidebar_ratio;
    if (ratio != before) {
        const edge = @min(24 / available, @min(limits.min, 1 - limits.max) / 2);
        if (ratio <= edge) {
            ratio = 0;
        } else if (ratio >= 1 - edge) {
            ratio = 1;
        } else {
            ratio = std.math.clamp(ratio, limits.min, limits.max);
        }
        app.sidebar_ratio = ratio;
        if (ratio == 1 and before != 1) {
            // A hidden editor no longer receives its focus-loss frame.
            if (app.selected_task_id != null) {
                const draft = app.draft();
                draft.history.cancelComposition(&draft.buffer);
            }
            app.rename_history.cancelComposition(&app.rename_buffer);
            app.edit_history.cancelComposition(&app.edit_buffer);
            dvui.focusWidget(null, null, null);
        }
    }
    if (panes.showFirst()) drawSidebar(app);
    if (panes.showSecond()) drawDetailPanel(app);
}

fn paneRatioLimits(available: f32) struct { min: f32, max: f32 } {
    // Budget both header rows, including a two-character detail title prefix.
    // DVUI measures text in layout units at the current zoom and display scale.
    const sidebar = 2 * sidebar_padding + 10 + dvui.Font.theme(.heading).textSize("事项").w +
        dvui.ButtonWidget.defaults.padSize(dvui.Font.theme(.body).textSize("新建")).w;
    const middle = headerButtonOptions(header_action_button_width, .middle, null);
    const trailing = headerButtonOptions(header_secondary_button_width, .trailing, null);
    const detail = 2 * detail_padding + 12 + dvui.Font.theme(.title).textSize("事项…").w +
        2 * middle.padSize(.width(header_action_button_width)).w + trailing.padSize(.width(header_secondary_button_width)).w;
    const budget = @max(available, sidebar + detail);
    return .{ .min = sidebar / budget, .max = @max(sidebar / budget, 1 - detail / budget) };
}

fn drawSidebar(app: *AppState) void {
    var sidebar = dvui.box(
        @src(),
        .{ .dir = .vertical },
        .{
            .expand = .both,
            .background = true,
            .style = .content,
            .padding = .all(sidebar_padding),
        },
    );
    defer sidebar.deinit();

    drawSidebarHeader(app);
    drawTaskFilters(app);

    var scroll = dvui.scrollArea(
        @src(),
        .{},
        .{ .expand = .both, .background = false },
    );
    defer scroll.deinit();

    if (app.tasks.items.len == 0) {
        dvui.label(@src(), "还没有事项。", .{}, .{});
        return;
    }

    if (!app.hasVisibleTasks()) {
        const message = switch (app.task_filter) {
            .active => "没有进行中的事项。",
            .completed => "还没有已完成的事项。",
            .all => unreachable,
        };
        dvui.labelNoFmt(@src(), message, .{}, .{});
        return;
    }

    for (app.tasks.items) |*task| {
        if (app.taskVisible(task)) drawTaskButton(app, task);
    }
}

fn drawSidebarHeader(app: *AppState) void {
    var header = dvui.box(
        @src(),
        .{ .dir = .horizontal },
        .{
            .expand = .horizontal,
            .margin = .{ .h = 2 },
        },
    );
    defer header.deinit();

    dvui.label(
        @src(),
        "事项",
        .{},
        .{
            .font = .theme(.heading),
            .expand = .horizontal,
            .gravity_y = 0.5,
            // Match the task text inset: 4 px margin + 6 px padding.
            .padding = .{ .x = 10 },
        },
    );

    if (dvui.button(@src(), "新建", .{}, .{ .style = .control, .tag = if (@import("builtin").is_test) "new-task" else null })) {
        if (app.sidebar_ratio == 1) app.sidebar_ratio = app.expanded_sidebar_ratio;
        app.pending = .create_task;
    }
}

fn drawTaskFilters(app: *AppState) void {
    const font = dvui.Font.theme(.body);
    // Each button needs its text plus horizontal padding, margins and border.
    const required_width = font.textSize("进行中").w + font.textSize("已完成").w + font.textSize("全部").w + 3 * 16;
    var row = dvui.box(
        @src(),
        .{ .dir = if (dvui.parentGet().data().contentRect().w < required_width) .vertical else .horizontal },
        .{
            .expand = .horizontal,
            .margin = .{ .y = 4, .h = 6 },
        },
    );
    defer row.deinit();

    drawTaskFilterButton(app, "进行中", .active);
    drawTaskFilterButton(app, "已完成", .completed);
    drawTaskFilterButton(app, "全部", .all);
}

fn drawTaskFilterButton(
    app: *AppState,
    label: []const u8,
    filter: TaskFilter,
) void {
    const selected = app.task_filter == filter;

    if (dvui.button(
        @src(),
        label,
        .{ .draw_focus = false },
        .{
            .tab_index = 0,
            .expand = .horizontal,
            .style = .window,
            .border = .all(1),
            .color_fill = if (selected) .{ .color = dvui.themeGet().focus.opacity(0.12) } else null,
            .color_text = if (selected) .{ .color = dvui.themeGet().focus } else null,
            .color_border = .{ .color = if (selected)
                dvui.themeGet().focus.opacity(0.55)
            else
                dvui.themeGet().border.opacity(0.24) },
            .padding = .{ .x = 5, .y = 4, .w = 5, .h = 4 },
            .margin = .{ .x = 2, .w = 2 },
            .id_extra = @backingInt(filter) + 1,
            .tag = if (@import("builtin").is_test) switch (filter) {
                .active => "filter-active",
                .completed => "filter-completed",
                .all => "filter-all",
            } else null,
        },
    )) {
        app.setTaskFilter(dvui.currentWindow().gpa, filter) catch {
            app.notice = .draft_unavailable;
        };
        dvui.focusWidget(null, null, null);
        dvui.refresh(null, @src(), null);
    }
}

fn drawTaskButton(app: *AppState, task: *const database.Task) void {
    const selected = app.selected_task_id != null and
        app.selected_task_id.? == task.id;
    const colors = dvui.themeGet();
    const text_color: ?dvui.ColorOrGradient = if (task.completed)
        .{ .color = colors.color(.app1, .text) }
    else
        null;

    var button: dvui.ButtonWidget = undefined;
    button.init(
        @src(),
        .{ .draw_focus = false },
        .{
            .tab_index = 0,
            .expand = .horizontal,
            .style = .content,
            .border = .{ .x = 3 },
            .color_fill = .{ .color = if (selected) colors.fill.lerp(colors.focus, 0.10) else colors.fill },
            .color_fill_hover = .{ .color = colors.fill.lerp(colors.focus, 0.15) },
            .color_fill_press = .{ .color = colors.fill.lerp(colors.focus, 0.22) },
            .color_text = text_color,
            .color_text_hover = text_color,
            .color_text_press = text_color,
            .color_border = .{ .color = if (selected) colors.focus else colors.focus.opacity(0) },
            .margin = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
            .padding = .all(6),
            .id_extra = idExtra(task.id),
            .tag = if (@import("builtin").is_test) task.title else null,
            .label = .{ .text = task.title },
        },
    );
    button.processEvents();
    button.drawBackground();
    user_text.label(@src(), task.title, button.data().options.strip().override(button.style()).override(.{
        .expand = .horizontal,
        .gravity_y = 0.5,
        .tag = entryTestTag("task-title", task.id),
    }));
    button.drawFocus();
    const clicked = button.clicked();
    button.deinit();
    if (clicked) {
        if (app.sidebar_ratio == 1) app.sidebar_ratio = app.expanded_sidebar_ratio;
        app.selectTask(dvui.currentWindow().gpa, task.id) catch {
            app.notice = .draft_unavailable;
        };
        dvui.focusWidget(null, null, null);
        dvui.refresh(null, @src(), null);
    }
}

fn drawDetailPanel(app: *AppState) void {
    var detail = dvui.box(
        @src(),
        .{ .dir = .vertical },
        .{
            .expand = .both,
            .background = true,
            .style = .window,
            .padding = .{ .x = detail_padding, .y = 12, .w = detail_padding, .h = 6 },
        },
    );
    defer detail.deinit();

    const task = app.selectedTask() orelse {
        switch (app.task_filter) {
            .active => {
                dvui.label(@src(), "没有进行中的事项", .{}, .{ .font = .theme(.title) });
                dvui.label(@src(), "可以新建事项，或查看已完成事项。", .{}, .{});
            },
            .completed => {
                dvui.label(@src(), "还没有已完成的事项", .{}, .{ .font = .theme(.title) });
                dvui.label(@src(), "完成的事项会保留在这里。", .{}, .{});
            },
            .all => {
                dvui.label(@src(), "没有可显示的事项", .{}, .{ .font = .theme(.title) });
                dvui.label(@src(), "点击左侧“新建”创建一个事项。", .{}, .{});
            },
        }
        drawNotice(app);
        return;
    };

    drawTaskHeader(app, task);
    drawDetailContent(app, task);
    drawNotice(app);
}

fn drawDetailContent(app: *AppState, task: *const database.Task) void {
    const handle_size: f32 = 8;
    var split_ratio: f32 = 0.5;
    var panes: dvui.PanedWidget = undefined;
    panes.init(
        @src(),
        .{
            .direction = .vertical,
            .collapsed_size = 0,
            .split_ratio = &split_ratio,
            .handle_size = handle_size,
            .handle_show_distance = 24,
        },
        .{ .expand = .both, .max_size_content = .zero },
    );
    defer panes.deinit();

    // Keep the chosen editor height when resizing the window. Neither pane
    // may collapse, and a small window must not overwrite the preferred height.
    const available = @max(1, panes.data().contentRect().h - handle_size);
    const minimum_height = @min(100, available / 2);
    const timeline_minimum = if (app.mode == .edit_entry) @min(180, available / 2) else minimum_height;
    const minimum_ratio = timeline_minimum / available;
    split_ratio = 1 - std.math.clamp(app.composer_height, minimum_height, available - timeline_minimum) / available;
    const previous_ratio = split_ratio;
    panes.processEvents();
    const dragged = split_ratio != previous_ratio;
    split_ratio = std.math.clamp(split_ratio, minimum_ratio, 1 - minimum_height / available);
    if (dragged) {
        app.composer_height = available * (1 - split_ratio);
    }

    if (panes.showFirst()) drawTimeline(app, task);
    if (panes.showSecond()) drawComposer(app, task.id);
}

fn drawTaskHeader(app: *AppState, task: *const database.Task) void {
    {
        // Display and rename controls differ slightly in natural height. Keep
        // this slot fixed so toggling them does not move the content below.
        var title_slot = dvui.box(
            @src(),
            .{ .dir = .vertical },
            .{
                .expand = .horizontal,
                .margin = .{ .y = 3, .h = 3 },
                .min_size_content = .height(30),
                .max_size_content = .height(30),
            },
        );
        defer title_slot.deinit();

        if (app.isRenamingTask(task.id)) {
            drawRenameEditor(app, task.id);
        } else {
            var title_row = dvui.box(
                @src(),
                .{ .dir = .horizontal },
                .{ .expand = .horizontal },
            );
            defer title_row.deinit();

            user_text.label(
                @src(),
                task.title,
                .{
                    .font = .theme(.title),
                    .background = false,
                    .expand = .horizontal,
                    .max_size_content = .width(0),
                    .gravity_y = 0.5,
                    .padding = .{ .x = 6, .w = 6 },
                },
            );

            const confirming_delete = app.isConfirmingTaskDeletion(task.id);

            if (confirming_delete) {
                if (dvui.button(
                    @src(),
                    "确认删除",
                    .{},
                    headerButtonOptions(header_action_button_width, .middle, .err),
                )) {
                    app.pending = .{ .delete_task = task.id };
                }

                if (dvui.button(
                    @src(),
                    "取消",
                    .{},
                    headerButtonOptions(header_secondary_button_width, .trailing, null),
                )) {
                    app.cancelMode();
                    dvui.refresh(null, @src(), null);
                }
            } else {
                var status_button_options = headerButtonOptions(
                    header_action_button_width,
                    .middle,
                    .app1,
                );
                status_button_options.tab_index = 0;

                if (dvui.button(
                    @src(),
                    if (task.completed) "重新打开" else "标记完成",
                    .{ .draw_focus = false },
                    status_button_options,
                )) {
                    app.pending = .{ .toggle_task_completed = task.id };
                    dvui.focusWidget(null, null, null);
                }

                if (dvui.button(
                    @src(),
                    "重命名",
                    .{},
                    headerButtonOptions(header_action_button_width, .middle, null).override(.{ .tag = if (@import("builtin").is_test) "task-rename" else null }),
                )) {
                    app.beginRename(task);
                    dvui.refresh(null, @src(), null);
                }

                if (dvui.button(
                    @src(),
                    "删除",
                    .{},
                    headerButtonOptions(header_secondary_button_width, .trailing, null).override(.{ .tag = if (@import("builtin").is_test) "task-delete" else null }),
                )) {
                    app.requestTaskDeletion(task.id);
                    dvui.refresh(null, @src(), null);
                }
            }
        }
    }
}

fn drawRenameEditor(app: *AppState, task_id: i64) void {
    var row = dvui.box(
        @src(),
        .{ .dir = .horizontal },
        .{ .expand = .horizontal },
    );
    defer row.deinit();

    var editor: dvui.TextEntryWidget = undefined;
    editor.init(
        @src(),
        .{
            .text = .{ .buffer = &app.rename_buffer },
            .placeholder = "事项名称",
        },
        .{
            .expand = .horizontal,
            .gravity_y = 0.5,
            .tag = if (@import("builtin").is_test) "rename" else null,
            .margin = .{ .w = 4 },
            .padding = .{ .x = 6, .y = 5, .w = 6, .h = 5 },
        },
    );

    if (dvui.firstFrame(editor.data().id)) {
        dvui.focusWidget(editor.data().id, null, null);
        editor.textLayout.selection.selectAll();
    }

    const edit_result = text_editor.process(&editor, &app.rename_history, false);
    if (edit_result.history_failed) app.notice = .history_unavailable;
    text_editor.draw(&editor);
    const enter_pressed = editor.enter_pressed;
    editor.deinit();

    const save_clicked = dvui.button(
        @src(),
        "保存",
        .{},
        headerButtonOptions(header_action_button_width, .middle, .highlight),
    );
    if (enter_pressed or save_clicked) {
        app.pending = .{ .rename_task = task_id };
    }

    if (dvui.button(
        @src(),
        "取消",
        .{},
        headerButtonOptions(header_secondary_button_width, .trailing, null),
    )) {
        app.cancelMode();
        dvui.refresh(null, @src(), null);
    }
}

fn drawTimeline(app: *AppState, task: *const database.Task) void {
    var timeline = dvui.scrollArea(
        @src(),
        .{},
        .{
            .expand = .both,
            // Entries scroll within the timeline and never push out the editor.
            .max_size_content = .height(0),
            .background = false,
            .style = .content,
            .border = .all(0),
            .padding = .all(4),
            .tag = if (@import("builtin").is_test) "timeline" else null,
        },
    );
    defer timeline.deinit();

    if (task.entries.items.len == 0) {
        dvui.label(@src(), "当前事项还没有进展。", .{}, .{});
        dvui.label(@src(), "在下面输入内容，然后点击“发送”。", .{}, .{});
        return;
    }

    for (task.entries.items, 0..) |*entry, index| {
        const scroll_here = app.scroll_to_latest and index + 1 == task.entries.items.len;
        drawEntryCard(app, entry, scroll_here, timeline.si.viewport.h);
    }
}

fn drawEntryCard(
    app: *AppState,
    entry: *const database.Entry,
    scroll_here: bool,
    viewport_height: f32,
) void {
    var card = dvui.box(
        @src(),
        .{ .dir = .vertical },
        .{
            .expand = .horizontal,
            .background = true,
            .style = .content,
            .border = .{ .h = 1 },
            .corners = .round(6),
            .padding = .all(10),
            .margin = .{ .x = 3, .y = 3, .w = 3, .h = 8 },
            .id_extra = idExtra(entry.id),
        },
    );
    defer card.deinit();

    if (app.isEditingEntry(entry.id)) {
        drawEntryEditor(app, entry.id, viewport_height);
        return;
    }

    var body = dvui.textLayout(
        @src(),
        .{ .break_lines = true, .cache_layout = true },
        .{ .expand = .horizontal, .background = false, .tag = entryTestTag("entry-body", entry.id) },
    );
    // TextLayout retains its selection across frames, including after losing focus.
    if (dvui.focusedWidgetId() != body.data().id) {
        body.selection.moveCursor(body.selection.cursor, false);
    }
    user_text.addText(body, entry.body, .{});
    body.deinit();

    const metadata_options: dvui.Options = .{
        .font = dvui.Font.theme(.body).withSize(11),
        .color_text = .{ .color = theme.mutedText() },
        .expand = .horizontal,
        .max_size_content = .width(0),
        .margin = .{ .y = 7 },
    };

    if (!entry.edited) {
        dvui.label(@src(), "创建 {s}", .{entry.created_text}, metadata_options);
    } else {
        dvui.label(
            @src(),
            "创建 {s} · 修改 {s}",
            .{ entry.created_text, entry.updated_text },
            metadata_options,
        );
    }

    var actions = dvui.box(
        @src(),
        .{ .dir = .horizontal },
        .{ .gravity_x = 1, .margin = .{ .y = 2 } },
    );
    defer actions.deinit();

    const confirming_delete = app.isConfirmingEntryDeletion(entry.id);

    if (confirming_delete) {
        if (dvui.button(@src(), "确认", .{}, .{ .style = .err })) {
            app.pending = .{ .delete_entry = entry.id };
        }
        if (dvui.button(@src(), "取消", .{}, .{ .margin = .{ .x = 4, .y = 4, .h = 4 } })) {
            app.cancelMode();
            dvui.refresh(null, @src(), null);
        }
    } else {
        if (dvui.button(@src(), "复制", .{}, entryActionOptions(entryTestTag("copy-entry", entry.id)))) {
            if (dvui.currentWindow().backend.clipboardTextSet(entry.body)) {
                app.notice = .entry_copied;
            } else |_| {
                app.notice = .clipboard_error;
            }
        }
        if (dvui.button(@src(), "编辑", .{}, entryActionOptions(entryTestTag("edit-entry", entry.id)))) {
            app.beginEntryEdit(entry);
            dvui.refresh(null, @src(), null);
        }
        if (dvui.button(@src(), "删除", .{}, entryActionOptions(entryTestTag("delete-entry", entry.id)))) {
            app.requestEntryDeletion(entry.id);
            dvui.refresh(null, @src(), null);
        }
    }

    if (scroll_here and !dvui.firstFrame(card.data().id)) {
        dvui.scrollTo(.{
            .screen_rect = actions.data().borderRectScale().r,
            .over_scroll = true,
        });
        app.scroll_to_latest = false;
    }
}

fn drawEntryEditor(app: *AppState, entry_id: i64, viewport_height: f32) void {
    // Reserve the card insets and action row inside the timeline viewport.
    // Actual wrapped text height comes from TextLayout, so resizing, pasting,
    // deleting and undo all use the same measurement as the rendered text.
    const maximum_height = @max(24, @min(360, viewport_height - 94));
    const minimum_height = @min(92, maximum_height);
    const height = std.math.clamp(app.edit_content_height, minimum_height, maximum_height);
    var editor: dvui.TextEntryWidget = undefined;
    editor.init(
        @src(),
        .{
            .text = .{ .buffer = &app.edit_buffer },
            .multiline = true,
            .break_lines = true,
            .scroll_horizontal = false,
            .placeholder = "修改进展内容……",
        },
        .{
            .expand = .horizontal,
            .min_size_content = .{ .h = height },
            .tag = if (@import("builtin").is_test) "entry-editor" else null,
            .max_size_content = dvui.Options.MaxSize.height(height),
            .margin = .{ .y = 4, .h = 4 },
        },
    );

    if (dvui.firstFrame(editor.data().id)) {
        dvui.focusWidget(editor.data().id, null, null);
        editor.textLayout.selection.moveCursor(std.math.maxInt(usize), false);
    }

    const edit_result = text_editor.process(&editor, &app.edit_history, true);
    if (edit_result.history_failed) app.notice = .history_unavailable;
    text_editor.draw(&editor);
    app.edit_content_height = editor.textLayout.data().min_size.h + 4;
    const resizing = @abs(std.math.clamp(app.edit_content_height, minimum_height, maximum_height) - height) > 0.5;
    if (resizing) {
        app.reveal_entry_editor = true;
        dvui.refresh(null, @src(), editor.data().id);
    }
    const first_frame = dvui.firstFrame(editor.data().id);
    editor.deinit();

    var buttons = dvui.box(
        @src(),
        .{ .dir = .horizontal },
        .{ .expand = .horizontal, .gravity_x = 1.0 },
    );
    defer buttons.deinit();

    drawHint(submit_key ++ " 保存 · Esc 取消", "edit-hint");

    const save_clicked = dvui.button(
        @src(),
        "保存修改",
        .{},
        .{ .style = .highlight, .tag = if (@import("builtin").is_test) "save-entry" else null },
    );
    if (edit_result.submit or save_clicked) {
        app.pending = .{ .update_entry = entry_id };
    }
    if (dvui.button(@src(), "取消", .{}, .{ .margin = .{ .x = 4, .y = 4, .h = 4 } })) {
        app.cancelMode();
        dvui.refresh(null, @src(), null);
    }
    if (app.reveal_entry_editor and !first_frame and !resizing) {
        dvui.scrollTo(.{ .screen_rect = buttons.data().borderRectScale().r });
        app.reveal_entry_editor = false;
    }
}

fn drawComposer(app: *AppState, task_id: i64) void {
    var composer = dvui.box(
        @src(),
        .{ .dir = .vertical },
        .{ .expand = .both, .max_size_content = .zero, .margin = .{ .h = 4 } },
    );
    defer composer.deinit();

    drawHint(submit_key ++ " 发送 · 拖动上方分隔条调整高度", "composer-hint");
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .max_size_content = .zero });
    defer row.deinit();

    var editor: dvui.TextEntryWidget = undefined;
    editor.init(
        @src(),
        .{
            .text = .{ .buffer = &app.draft().buffer },
            .multiline = true,
            .break_lines = true,
            .scroll_horizontal = false,
            .placeholder = "输入当前事项的最新进展……",
        },
        .{
            .expand = .both,
            // Wrapped text scrolls inside its allocation; its measured size
            // must never consume the space reserved for the send button.
            .min_size_content = .zero,
            .max_size_content = .zero,
            .margin = .{ .w = 4 },
            .id_extra = idExtra(task_id),
            .tag = if (@import("builtin").is_test) "composer" else null,
        },
    );

    if (app.focus_composer) {
        dvui.focusWidget(editor.data().id, null, null);
        app.focus_composer = false;
    }

    const edit_result = text_editor.process(&editor, &app.draft().history, true);
    if (edit_result.history_failed) app.notice = .history_unavailable;
    text_editor.draw(&editor);
    editor.deinit();

    const send_clicked = dvui.button(
        @src(),
        "发送",
        .{},
        .{
            .style = .highlight,
            .gravity_y = 1.0,
            .min_size_content = .{ .w = 70, .h = 34 },
            .margin = .{ .x = 4 },
            .tag = if (@import("builtin").is_test) "send-entry" else null,
        },
    );
    if (edit_result.submit or send_clicked) {
        app.pending = .{ .create_entry = task_id };
    }
}

fn drawNotice(app: *const AppState) void {
    const message: []const u8 = switch (app.notice) {
        .none => if (app.mode == .rename_task) "Enter 保存名称 · Esc 取消" else "",
        .confirm_delete_task => "删除事项及全部进展？按 Esc 取消。",
        .confirm_delete_entry => "确定删除这条进展？按 Esc 取消。",
        .empty_title => "事项名称不能为空。",
        .empty_entry => "进展内容不能为空。",
        .task_created => "事项已创建。Enter 保存名称 · Esc 取消。",
        .task_renamed => "事项名称已更新。",
        .task_completed => "事项已完成。",
        .task_reopened => "事项已重新打开。",
        .task_deleted => "事项已删除。",
        .entry_created => "进展已发送。",
        .entry_updated => "进展已修改。",
        .entry_deleted => "进展已删除。",
        .entry_copied => "已复制整条进展。",
        .clipboard_error => "复制失败，请重试。",
        .database_error => "数据操作未完成，请检查记录后重试。",
        .draft_unavailable => "无法打开该事项的输入区，当前草稿已保留。",
        .history_unavailable => "无法保留撤销历史，当前文字仍已保留。",
        .preferences_unavailable => "缩放偏好读写失败，本次仍可调整和记录。",
    };

    const notice_font = dvui.Font.theme(.body).withSize(11).withLineHeight(1.0);
    const failed = switch (app.notice) {
        .confirm_delete_task,
        .confirm_delete_entry,
        .empty_title,
        .empty_entry,
        .database_error,
        .draft_unavailable,
        .history_unavailable,
        .clipboard_error,
        .preferences_unavailable,
        => true,
        else => false,
    };
    const color = if (failed)
        dvui.Color.fromHex(if (dvui.themeGet().dark) "#ffb4ab" else "#b42318")
    else if (app.notice == .none)
        theme.mutedText()
    else
        dvui.Color.fromHex(if (dvui.themeGet().dark) "#9ad7b0" else "#28613a");

    // Reserve one line even when empty so notices never shift the editor.
    const notice_height: f32 = 16;
    dvui.labelNoFmt(
        @src(),
        message,
        .{},
        .{
            .font = notice_font,
            .color_text = .{ .color = color },
            .background = app.notice != .none,
            .color_fill = .{ .color = dvui.themeGet().fill.lerp(color, 0.08) },
            .color_border = .{ .color = color },
            .border = .{ .x = if (app.notice != .none) 3 else 0 },
            .expand = .horizontal,
            .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
            .margin = .{ .y = 2 },
            .min_size_content = .height(notice_height),
            .max_size_content = .{ .w = 0, .h = notice_height },
            .tag = if (@import("builtin").is_test) "notice" else null,
        },
    );
}

fn drawHint(message: []const u8, tag: []const u8) void {
    dvui.labelNoFmt(@src(), message, .{}, .{
        .font = dvui.Font.theme(.body).withSize(10),
        .color_text = .{ .color = theme.mutedText() },
        .expand = .horizontal,
        .max_size_content = .width(0),
        .padding = .{ .y = 3, .h = 3 },
        .tag = if (@import("builtin").is_test) tag else null,
    });
}

fn entryTestTag(comptime prefix: []const u8, entry_id: i64) ?[]const u8 {
    if (!@import("builtin").is_test) return null;
    return std.fmt.allocPrint(dvui.currentWindow().arena(), prefix ++ "-{d}", .{entry_id}) catch unreachable;
}

fn entryActionOptions(tag: ?[]const u8) dvui.Options {
    return .{
        .font = dvui.Font.theme(.body).withSize(11),
        .color_text = .{ .color = theme.mutedText() },
        .color_fill = .{ .color = dvui.themeGet().fill },
        .color_fill_hover = .{ .color = dvui.themeGet().focus.opacity(0.10) },
        .color_fill_press = .{ .color = dvui.themeGet().focus.opacity(0.18) },
        .padding = .{ .x = 7, .y = 4, .w = 7, .h = 4 },
        .margin = .{ .x = 2 },
        .tag = if (@import("builtin").is_test) tag else null,
    };
}

fn idExtra(id: i64) usize {
    std.debug.assert(id >= 0);
    return @intCast(id);
}

fn headerButtonOptions(
    width: f32,
    position: HeaderControlPosition,
    style: ?dvui.Theme.Style.Name,
) dvui.Options {
    return .{
        .style = style,
        .min_size_content = .width(width),
        .max_size_content = .width(width),
        .gravity_y = 0.5,
        .margin = switch (position) {
            .middle => .{ .x = 4, .w = 4 },
            .trailing => .{ .x = 4 },
        },
        .padding = .{ .x = 6, .y = 5, .w = 6, .h = 5 },
    };
}
