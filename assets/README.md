# Matterlog 资源

- [`matterlog-icon.png`](matterlog-icon.png)：已裁紧透明留白的 PNG 原图，也用于非 Windows 平台的运行时窗口图标。
- [`matterlog.ico`](matterlog.ico)：由 PNG 原图生成，程序、窗口和托盘共用，包含 16、20、24、32、40、48、64、128 和 256 像素，图案与留白均与 PNG 一致。
- [`matterlog.rc`](matterlog.rc)：将 ICO 嵌入 Windows EXE，供资源管理器和系统界面使用。
- [`fonts/`](fonts/)：HarmonyOS Sans SC 字体、来源说明与许可证。
- [`matterlog-screenshot.png`](matterlog-screenshot.png)：README 中的界面展示截图。

图标以进展时间线和三条日志内容为主体，最后一个琥珀色节点表示最新进展。

运行所需的字体和图标在编译时嵌入程序，运行时不需要此目录。字体许可证副本随发布程序一同提供。
