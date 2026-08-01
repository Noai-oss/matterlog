# Matterlog

Matterlog 是一个使用 Zig、DVUI 和 SQLite 编写的本地事项进展记录工具，
支持事项的新建、选择、重命名和删除，以及进展的新增、编辑和删除。

## 环境

- Zig 0.16.0
- DVUI 0.5.0-dev（`main` @ `7426b65`，由 `build.zig.zon` 锁定）
- SQLite 3.53.4（源码已放在 `vendor/sqlite`）
- 字体：HarmonyOS Sans SC（许可文件随构建产物安装）

首次构建需要联网下载 DVUI，之后可以使用本地 Zig 缓存。

## 开发

```powershell
# 运行
zig build sdl3-app

# 只编译
zig build compile-sdl3-app

# 测试
zig build test
```

新增或编辑进展时按 `Ctrl + Enter`（macOS 为 `Cmd + Enter`）可提交；双击
进展正文可进入编辑。重命名、编辑或删除确认状态下按 `Esc` 可退出当前操作，
未发送的进展草稿不会被清空。

## 数据

应用通过 SDL 的用户偏好目录保存数据库。在 Windows 上通常是：

```text
%APPDATA%\Matterlog\Matterlog\matterlog.db
```

## Windows 可执行文件

已编译的 Windows x86_64 程序位于 `release/windows-x86_64/`。重新生成：

```powershell
zig build -Doptimize=ReleaseFast
Copy-Item zig-out/bin/matterlog.exe release/windows-x86_64/matterlog.exe
Copy-Item src/fonts/LICENSE.txt release/windows-x86_64/HarmonyOS-Sans-LICENSE.txt
```

## 源码结构

```text
src/main.zig                        DVUI/SDL 应用入口与主题
src/app_state.zig                   应用状态与业务动作
src/ui.zig                          界面布局与交互
src/database.zig                    SQLite 数据访问
src/fonts/                          HarmonyOS Sans SC 与字体许可证
assets/                             应用图标 PNG、ICO 与 Windows 资源
vendor/sqlite/                      SQLite amalgamation、版本与哈希
release/windows-x86_64/             Windows x86_64 发布文件
build.zig                           构建入口
```
