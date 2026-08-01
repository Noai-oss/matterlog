$ErrorActionPreference = 'Stop'

$VersionName = '3.53.4'
$VersionCode = '3530400'
$DownloadUrl = "https://www.sqlite.org/2026/sqlite-amalgamation-$VersionCode.zip"
$ExpectedArchiveSha256 = '1e71ddf93849c6a6ecf58b827c0692073d2dd7ee40196158068f7b29f422e87d'
$ExpectedFileSha256 = @{
    'sqlite3.c' = 'b1dd5d74ec7f29055a6684fa06fb3c2f6821c87dd38f9a458dfd2e8a1db28189'
    'sqlite3.h' = '919e7f2e8ed1d8f56ac17b412b8971c76aa5d1a879752cc6058f75e7d5910e1d'
}

$Archive = Join-Path $env:TEMP "sqlite-amalgamation-$VersionCode.zip"
$Extract = Join-Path $env:TEMP "sqlite-amalgamation-$VersionCode"
$Target = Join-Path $PSScriptRoot 'vendor/sqlite'

try {
    for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
        try {
            Invoke-WebRequest -Uri $DownloadUrl -OutFile $Archive
            break
        }
        catch {
            if ($Attempt -eq 3) {
                throw
            }
            Write-Warning "SQLite download attempt $Attempt failed; retrying..."
            Start-Sleep -Seconds $Attempt
        }
    }

    $ArchiveSha256 = (Get-FileHash $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ArchiveSha256 -ne $ExpectedArchiveSha256) {
        throw "SQLite archive SHA-256 mismatch: expected $ExpectedArchiveSha256, got $ArchiveSha256"
    }

    Remove-Item $Extract -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $Archive -DestinationPath $env:TEMP -Force

    foreach ($FileName in $ExpectedFileSha256.Keys) {
        $SourceFile = Join-Path $Extract $FileName
        $ActualSha256 = (Get-FileHash $SourceFile -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($ActualSha256 -ne $ExpectedFileSha256[$FileName]) {
            throw "$FileName SHA-256 mismatch: expected $($ExpectedFileSha256[$FileName]), got $ActualSha256"
        }
    }

    New-Item -ItemType Directory -Path $Target -Force | Out-Null
    Copy-Item (Join-Path $Extract 'sqlite3.c') $Target -Force
    Copy-Item (Join-Path $Extract 'sqlite3.h') $Target -Force

    Write-Host "SQLite $VersionName source installed in $Target (SHA-256 verified)"
}
finally {
    Remove-Item $Archive -Force -ErrorAction SilentlyContinue
    Remove-Item $Extract -Recurse -Force -ErrorAction SilentlyContinue
}
