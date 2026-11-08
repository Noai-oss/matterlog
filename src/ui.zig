const std = @import("std");
const dvui = @import("dvui");
const database = @import("database.zig");
const state = @import("app_state.zig");
const text_editor = @import("text_editor.zig");

const AppState = state.AppState;
const TaskFilter = state.TaskFilter;
const header_action_button_width: f32 = 64;
const header_secondary_button_width: f32 = 32;

const HeaderControlPosition = enum { middle, trailing };

pub fn draw(app: *AppState) void {
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
}

fn processEscapeShortcut(app: *AppState, root_data: *dvui.WidgetData) void {
    if (!app.hasActiveMode()) return;
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
    var panes = dvui.paned(
        @src(),
        .{
            .direction = .horizontal,
            .collapsed_size = 0,
            .split_ratio = &app.sidebar_ratio,
            // Keep the handle width stable while hovering to prevent jitter.
            .handle_size = 6,
            .handle_margin = 2,
        },
        .{ .expand = .both, .background = false },
    );
    defer panes.deinit();

    if (panes.showFirst()) drawSidebar(app);
    if (panes.showSecond()) drawDetailPanel(app);
}

fn drawSidebar(app: *AppState) void {
    var sidebar = dvui.box(
        @src(),
        .{ .dir = .vertical },
        .{
            .expand = .both,
            .background = true,
            .style = .content,
            .padding = .all(10),
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
        app.pending = .create_task;
    }
}

fn drawTaskFilters(app: *AppState) void {
    var row = dvui.box(
        @src(),
        .{ .dir = .horizontal },
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
    const theme = dvui.themeGet();
    const text_color: ?dvui.ColorOrGradient = if (task.completed)
        .{ .color = theme.color(.app1, .text) }
    else
        null;

    if (dvui.button(
        @src(),
        task.title,
        .{ .draw_focus = false },
        .{
            .tab_index = 0,
            .expand = .horizontal,
            .style = .content,
            .border = .{ .x = 3 },
            .color_fill = .{ .color = theme.fill },
            .color_fill_hover = .{ .color = theme.color(.window, .fill) },
            .color_fill_press = .{ .color = theme.color(.control, .fill) },
            .color_text = text_color,
            .color_text_hover = text_color,
            .color_text_press = text_color,
            .color_border = .{ .color = if (selected) theme.focus else theme.focus.opacity(0) },
            .margin = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
            .padding = .all(6),
            .id_extra = idExtra(task.id),
            .tag = if (@import("builtin").is_test) task.title else null,
        },
    )) {
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
            .padding = .{ .x = 12, .y = 12, .w = 12, .h = 6 },
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

            dvui.labelNoFmt(
                @src(),
                task.title,
                .{},
                .{
                    .font = .theme(.title),
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
                    headerButtonOptions(header_action_button_width, .middle, null),
                )) {
                    app.beginRename(task);
                    dvui.refresh(null, @src(), null);
                }

                if (dvui.button(
                    @src(),
                    "删除",
                    .{},
                    headerButtonOptions(header_secondary_button_width, .trailing, null),
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
    editor.draw();
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
            .background = true,
            .style = .content,
            .border = .all(1),
            .padding = .all(10),
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
            .style = .control,
            .border = .all(1),
            .padding = .all(8),
            .margin = .all(3),
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
        .{ .expand = .horizontal, .background = false },
    );
    body.addText(entry.body, .{});
    const edit_double_clicked = entryBodyDoubleClicked(app, body, entry.id);
    body.deinit();

    if (edit_double_clicked) {
        app.beginEntryEdit(entry);
        dvui.refresh(null, @src(), null);
        return;
    }

    var actions = dvui.box(
        @src(),
        .{ .dir = .horizontal },
        .{ .expand = .horizontal },
    );
    defer actions.deinit();

    const metadata_options: dvui.Options = .{
        .font = dvui.Font.theme(.body).withSize(9),
        .color_text = .{ .color = dvui.themeGet().text.opacity(0.42) },
        .expand = .horizontal,
        .gravity_y = 0.5,
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
        if (dvui.button(@src(), "编辑", .{}, .{})) {
            app.beginEntryEdit(entry);
            dvui.refresh(null, @src(), null);
        }
        if (dvui.button(@src(), "删除", .{}, .{ .margin = .{ .x = 4, .y = 4, .h = 4 } })) {
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
    editor.draw();
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
        .{ .dir = .horizontal },
        .{ .expand = .both, .max_size_content = .zero, .margin = .{ .h = 4 } },
    );
    defer composer.deinit();

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
    editor.draw();
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
        },
    );
    if (edit_result.submit or send_clicked) {
        app.pending = .{ .create_entry = task_id };
    }
}

fn entryBodyDoubleClicked(
    app: *AppState,
    body: *dvui.TextLayoutWidget,
    entry_id: i64,
) bool {
    const click_event = body.click_event orelse return false;
    if (click_event != .mouse or click_event.mouse.button != .left) return false;

    const point = click_event.mouse.p;
    const now = dvui.frameTimeNS();
    const is_double_click = if (app.last_entry_click) |last| blk: {
        const distance = point.diff(.{ .x = last.x, .y = last.y }).toNatural();
        break :blk last.entry_id == entry_id and
            now >= last.time_ns and
            now - last.time_ns <= 500_000_000 and
            @abs(distance.x) <= dvui.Dragging.threshold and
            @abs(distance.y) <= dvui.Dragging.threshold;
    } else false;

    if (is_double_click) {
        app.last_entry_click = null;
    } else {
        app.last_entry_click = .{
            .entry_id = entry_id,
            .time_ns = now,
            .x = point.x,
            .y = point.y,
        };
    }
    return is_double_click;
}

fn drawNotice(app: *const AppState) void {
    const message: []const u8 = switch (app.notice) {
        .none => "",
        .confirm_delete_task => "删除事项会同时删除其中的所有进展。",
        .confirm_delete_entry => "确定删除这条进展？",
        .empty_title => "事项名称不能为空。",
        .empty_entry => "进展内容不能为空。",
        .task_created => "事项已创建，可以直接修改名称。",
        .task_renamed => "事项名称已更新。",
        .task_completed => "事项已完成。",
        .task_reopened => "事项已重新打开。",
        .task_deleted => "事项已删除。",
        .entry_created => "进展已发送。",
        .entry_updated => "进展已修改。",
        .entry_deleted => "进展已删除。",
        .database_error => "数据库操作失败，请查看终端日志。",
        .draft_unavailable => "无法打开该事项的输入区，当前草稿已保留。",
        .history_unavailable => "无法保留撤销历史，当前文字仍已保留。",
    };

    const notice_font = dvui.Font.theme(.body).withSize(9).withLineHeight(1.0);
    const color = switch (app.notice) {
        .none => dvui.themeGet().text.opacity(0),
        .confirm_delete_task,
        .confirm_delete_entry,
        .empty_title,
        .empty_entry,
        .database_error,
        .draft_unavailable,
        .history_unavailable,
        => dvui.themeGet().color(.err, .fill),
        else => dvui.themeGet().focus,
    };

    // Reserve one line even when empty so notices never shift the editor.
    const notice_height = notice_font.textHeight();
    dvui.labelNoFmt(
        @src(),
        message,
        .{},
        .{
            .font = notice_font,
            .color_text = .{ .color = color },
            .expand = .horizontal,
            .padding = .{},
            .margin = .{ .x = 4, .w = 4 },
            .min_size_content = .height(notice_height),
            .max_size_content = .height(notice_height),
        },
    );
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
