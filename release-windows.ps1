#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$ManifestPath = Join-Path $PSScriptRoot 'build.zig.zon'
$ReadmePath = Join-Path $PSScriptRoot 'packaging/windows/README.md'
$ProjectLicensePath = Join-Path $PSScriptRoot 'LICENSE'
$FontLicensePath = Join-Path $PSScriptRoot 'assets/fonts/LXGWWenKai-LICENSE.txt'
$EmojiLicensePath = Join-Path $PSScriptRoot 'assets/fonts/NotoEmoji-LICENSE.txt'
foreach ($InputPath in @($ManifestPath, $ReadmePath, $ProjectLicensePath, $FontLicensePath, $EmojiLicensePath)) {
    if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
        throw "Required input not found: $InputPath"
    }
}

# Fail on an absent or ambiguous version instead of guessing a package name.
$VersionFields = [regex]::Matches(
    (Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8),
    '(?m)^\s*\.version\s*=\s*"([^"]+)"\s*,'
)
if ($VersionFields.Count -ne 1) {
    throw 'Expected exactly one project version in build.zig.zon.'
}
$Version = $VersionFields[0].Groups[1].Value
if ($Version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
    throw "Invalid project version in build.zig.zon: $Version"
}

$ReleaseRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'release'))
$ZipPath = Join-Path $ReleaseRoot "matterlog-v$Version-windows-x86_64.zip"
# Use a fresh install/staging directory so old outputs cannot enter the ZIP.
$WorkDir = Join-Path $ReleaseRoot ('.package-' + [guid]::NewGuid().ToString('N'))
$InstallDir = Join-Path $WorkDir 'install'
$PackageDir = Join-Path $WorkDir 'matterlog'
$StagedZip = Join-Path $WorkDir 'package.zip'

Push-Location -LiteralPath $PSScriptRoot
try {
    New-Item -ItemType Directory -Path $PackageDir -Force | Out-Null

    & zig build -Dtarget=x86_64-windows-gnu -Dcpu=baseline -Doptimize=ReleaseFast --prefix $InstallDir
    if ($LASTEXITCODE -ne 0) {
        throw "zig build failed with exit code $LASTEXITCODE."
    }

    Copy-Item -LiteralPath (Join-Path $InstallDir 'bin/matterlog.exe') -Destination $PackageDir
    Copy-Item -LiteralPath $ReadmePath -Destination (Join-Path $PackageDir 'README.md')
    Copy-Item -LiteralPath $ProjectLicensePath -Destination (Join-Path $PackageDir 'LICENSE.txt')
    Copy-Item -LiteralPath $FontLicensePath -Destination (Join-Path $PackageDir 'LXGWWenKai-LICENSE.txt')
    Copy-Item -LiteralPath $EmojiLicensePath -Destination (Join-Path $PackageDir 'NotoEmoji-LICENSE.txt')

    Compress-Archive -LiteralPath $PackageDir -DestinationPath $StagedZip -CompressionLevel Optimal
    Move-Item -LiteralPath $StagedZip -Destination $ZipPath -Force
}
finally {
    Pop-Location
    if (Test-Path -LiteralPath $WorkDir) {
        $ResolvedWorkDir = (Resolve-Path -LiteralPath $WorkDir).ProviderPath
        if ([IO.Path]::GetDirectoryName($ResolvedWorkDir) -ne $ReleaseRoot) {
            throw "Refusing to clean a directory outside the release directory: $ResolvedWorkDir"
        }
        Remove-Item -LiteralPath $ResolvedWorkDir -Recurse -Force
    }
}

Write-Host "Created ZIP: $ZipPath"
