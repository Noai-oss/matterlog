# Matterlog for Windows x86_64

- 应用版本：0.1.0
- 构建工具：Zig 0.17.0
- 优化模式：ReleaseFast
- 目标平台：Windows x86_64
- EXE SHA-256：`62098418993B5FED5AC183D0656D911D779C0FD3BE49BC8B85E2600E625D4174`

`matterlog.exe` 已嵌入运行所需的中文字体，无需安装字体或复制 DLL。
`HarmonyOS-Sans-LICENSE.txt` 是随字体分发的许可证文件。
`LICENSE.txt` 是 Matterlog 的 MIT 许可证。

关闭窗口会隐藏到系统托盘。点击或右键托盘图标，选择“打开 Matterlog”恢复窗口，选择“退出”关闭程序。

重复启动会唤起已有窗口，不会再打开第二个窗口；当前事项和未发送草稿会保留。

从仓库根目录重新生成：

```powershell
.\release-windows.ps1
```
