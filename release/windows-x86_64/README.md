# Matterlog for Windows x86_64

- 应用版本：0.1.0
- 构建工具：Zig 0.16.0
- 优化模式：ReleaseFast
- 目标平台：Windows x86_64
- EXE SHA-256：`889195A18511E0638521162830F105A7D4323C26F5E4F5834A6F169CB0B5899F`

`matterlog.exe` 已嵌入运行所需的中文字体，无需安装字体或复制 DLL。
`HarmonyOS-Sans-LICENSE.txt` 是随字体分发的许可证文件。

从仓库根目录重新生成：

```powershell
zig build -Doptimize=ReleaseFast
Copy-Item zig-out/bin/matterlog.exe release/windows-x86_64/matterlog.exe
Copy-Item src/fonts/LICENSE.txt release/windows-x86_64/HarmonyOS-Sans-LICENSE.txt
```
