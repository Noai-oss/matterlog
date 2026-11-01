$ErrorActionPreference = 'Stop'

$ZigVersion = (zig version).Trim()
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

zig build -Doptimize=ReleaseFast
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Copy-Item zig-out/bin/matterlog.exe release/windows-x86_64/matterlog.exe -Force
Copy-Item assets/fonts/LICENSE.txt release/windows-x86_64/HarmonyOS-Sans-LICENSE.txt -Force
Copy-Item LICENSE release/windows-x86_64/LICENSE.txt -Force

$Sha256 = (Get-FileHash release/windows-x86_64/matterlog.exe -Algorithm SHA256).Hash
$Readme = 'release/windows-x86_64/README.md'
$Content = Get-Content $Readme -Raw -Encoding UTF8
if ($Content -notmatch 'EXE SHA-256：`[0-9A-Fa-f]{64}`') {
    throw 'README 中未找到 EXE SHA-256'
}
$Content = $Content -replace 'EXE SHA-256：`[0-9A-Fa-f]{64}`', "EXE SHA-256：``$Sha256``"
if ($Content -notmatch '(?m)^- 构建工具：Zig [^\r\n]+') {
    throw 'README 中未找到 Zig 构建工具版本'
}
$Content = $Content -replace '(?m)^- 构建工具：Zig [^\r\n]+', "- 构建工具：Zig $ZigVersion"
[System.IO.File]::WriteAllText($Readme, $Content, [System.Text.UTF8Encoding]::new($false))

Write-Host "matterlog.exe SHA-256: $Sha256"
