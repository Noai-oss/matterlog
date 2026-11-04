const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const build_options = b.addOptions();
    build_options.addOption([:0]const u8, "app_version", @import("build.zig.zon").version);

    const sqlite = Translator.init(b.dependency("translate_c", .{}), .{
        .c_source_file = b.path("vendor/sqlite/sqlite3.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
    });

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,

        // database.zig 使用 SQLite C API，因此需要链接 libc。
        .link_libc = true,
    });

    module.addOptions("build_options", build_options);
    module.addImport(
        "dvui",
        dvui_dep.module("dvui_sdl3"),
    );

    // 直接使用 SDL3 设置应用元数据并获取用户偏好目录。
    module.addImport(
        "sdl-backend",
        dvui_dep.module("sdl3"),
    );
    // 将 assets 中的文件提供给 @embedFile，资源仍在编译时嵌入程序。
    module.addAnonymousImport("harmonyos-sans-sc", .{
        .root_source_file = b.path("assets/fonts/HarmonyOS_Sans_SC.ttf"),
    });
    module.addAnonymousImport("matterlog-icon", .{
        .root_source_file = b.path("assets/matterlog-icon.png"),
    });
    addSqlite(b, module, sqlite.mod);
    module.addWin32ResourceFile(.{
        .file = b.path("assets/matterlog.rc"),
    });

    const executable = b.addExecutable(.{
        .name = "matterlog",
        .root_module = module,
    });
    if (target.result.os.tag == .windows) {
        executable.subsystem = .windows;
    }

    const install_executable = b.addInstallArtifact(
        executable,
        .{},
    );
    const install_font_license = b.addInstallFileWithDir(
        b.path("assets/fonts/LICENSE.txt"),
        .prefix,
        "bin/HarmonyOS-Sans-LICENSE.txt",
    );
    const install_project_license = b.addInstallFileWithDir(
        b.path("LICENSE"),
        .prefix,
        "bin/LICENSE.txt",
    );

    b.getInstallStep().dependOn(&install_executable.step);
    b.getInstallStep().dependOn(&install_font_license.step);
    b.getInstallStep().dependOn(&install_project_license.step);

    const run_command = b.addRunArtifact(executable);

    run_command.addPassthruArgs();

    const run_step = b.step(
        "run",
        "Run Matterlog",
    );
    run_step.dependOn(&run_command.step);

    const database_test_module = b.createModule(.{
        .root_source_file = b.path("src/database.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addSqlite(b, database_test_module, sqlite.mod);

    const database_tests = b.addTest(.{
        .name = "matterlog-database-tests",
        .root_module = database_test_module,
    });
    const run_database_tests = b.addRunArtifact(database_tests);

    const state_test_module = b.createModule(.{
        .root_source_file = b.path("src/app_state.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addSqlite(b, state_test_module, sqlite.mod);

    const state_tests = b.addTest(.{
        .name = "matterlog-state-tests",
        .root_module = state_test_module,
    });
    const run_state_tests = b.addRunArtifact(state_tests);

    const dvui_testing = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .testing,
    });
    const editor_test_module = b.createModule(.{
        .root_source_file = b.path("src/ui_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    editor_test_module.addImport("dvui", dvui_testing.module("dvui_testing"));
    addSqlite(b, editor_test_module, sqlite.mod);
    const editor_tests = b.addTest(.{
        .name = "matterlog-editor-tests",
        .root_module = editor_test_module,
    });

    const test_step = b.step("test", "Run Matterlog tests");
    test_step.dependOn(&run_database_tests.step);
    test_step.dependOn(&run_state_tests.step);
    test_step.dependOn(&b.addRunArtifact(editor_tests).step);
}

fn addSqlite(b: *std.Build, module: *std.Build.Module, bindings: *std.Build.Module) void {
    module.addImport("sqlite", bindings);
    module.addIncludePath(b.path("vendor/sqlite"));
    module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-std=c11",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_THREADSAFE=1",
        },
    });
}
