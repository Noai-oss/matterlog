# Matterlog for Windows x86_64

- 应用版本：0.1.0
- 构建工具：Zig 0.16.0
- 优化模式：ReleaseFast
- 目标平台：Windows x86_64
- EXE SHA-256：`D3CDB3807B112CC41265F03D07D2522E92E7F4E3A6FAD4269A443D1772359253`

`matterlog.exe` 已嵌入运行所需的中文字体，无需安装字体或复制 DLL。
`HarmonyOS-Sans-LICENSE.txt` 是随字体分发的许可证文件。
`LICENSE.txt` 是 Matterlog 的 MIT 许可证。

从仓库根目录重新生成：

```powershell
zig build -Doptimize=ReleaseFast
Copy-Item zig-out/bin/matterlog.exe release/windows-x86_64/matterlog.exe
Copy-Item src/fonts/LICENSE.txt release/windows-x86_64/HarmonyOS-Sans-LICENSE.txt
Copy-Item LICENSE release/windows-x86_64/LICENSE.txt
```
