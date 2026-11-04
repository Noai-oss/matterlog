# Matterlog for Windows x86_64

解压 ZIP 后，打开 `matterlog` 文件夹，双击 `matterlog.exe` 启动。
程序已嵌入中文字体，无需安装字体或额外复制 DLL。

关闭窗口或按 `Alt + F4` 会隐藏到系统托盘，当前事项和未发送草稿会保留。
点击或右键托盘图标，选择“打开 Matterlog”恢复窗口，选择“退出”关闭程序。
如果系统托盘不可用，关闭窗口会直接退出程序。

重复启动会唤起已有窗口，不会打开第二个窗口；当前事项和未发送草稿不变。

运行期间，切换事项会保留各自的草稿；从托盘退出程序后不保留草稿。
编辑文字时，`Ctrl + Z` 撤销，`Ctrl + Y` 或 `Ctrl + Shift + Z` 重做；`Ctrl + Enter` 提交进展。

数据保存在用户目录中，Windows 上通常为：

```text
%APPDATA%\Matterlog\matterlog.db
```

数据不保存在解压目录中。备份或替换数据库前，请先从托盘菜单退出程序。

`LICENSE.txt` 是 Matterlog 的 MIT 许可证。
`HarmonyOS-Sans-LICENSE.txt` 是随程序分发的字体许可证。
