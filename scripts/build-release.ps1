[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$rootDir = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$packageJsonPath = Join-Path $rootDir 'package.json'
$manifestPath = Join-Path $rootDir 'release-manifest.json'

if (-not (Test-Path -LiteralPath $packageJsonPath -PathType Leaf)) {
    throw "package.json not found: $packageJsonPath"
}
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "release manifest not found: $manifestPath"
}

$packageJson = Get-Content -LiteralPath $packageJsonPath -Raw -Encoding utf8 |
    ConvertFrom-Json
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 |
    ConvertFrom-Json
$version = [string]$packageJson.version

if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Unsupported package version: $version"
}
if (-not $manifest.files -or $manifest.files.Count -eq 0) {
    throw 'release-manifest.json must contain at least one file.'
}

$releaseName = "HonorShareKeepAlive-v$version"
$distDir = Join-Path $rootDir 'dist'
$stageDir = Join-Path $distDir $releaseName
$zipPath = Join-Path $distDir "$releaseName.zip"
$checksumPath = Join-Path $distDir 'SHA256SUMS.txt'
$rootPrefix = $rootDir.TrimEnd('\') + '\'

function Assert-PathInsideRoot {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to write outside the project root: $fullPath"
    }
    return $fullPath
}

$distDir = Assert-PathInsideRoot $distDir
$stageDir = Assert-PathInsideRoot $stageDir
$zipPath = Assert-PathInsideRoot $zipPath
$checksumPath = Assert-PathInsideRoot $checksumPath

New-Item -ItemType Directory -Force -Path $distDir | Out-Null
if (Test-Path -LiteralPath $stageDir) {
    Remove-Item -LiteralPath $stageDir -Recurse -Force
}
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

foreach ($relativePathValue in $manifest.files) {
    $relativePath = ([string]$relativePathValue).Replace('\', '/').TrimStart('/')
    $segments = @($relativePath.Split('/'))

    if (
        -not $relativePath -or
        $segments -contains '..' -or
        $segments -contains '.git' -or
        $segments -contains '.runtime' -or
        $segments -contains 'logs' -or
        $segments -contains 'node_modules' -or
        $segments -contains 'dist'
    ) {
        throw "Unsafe release path: $relativePath"
    }

    $sourcePath = Assert-PathInsideRoot (Join-Path $rootDir $relativePath)
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Release file not found: $relativePath"
    }

    $destinationPath = Assert-PathInsideRoot (Join-Path $stageDir $relativePath)
    $destinationParent = Split-Path -Parent $destinationPath
    New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath
}

Compress-Archive -Path $stageDir -DestinationPath $zipPath -CompressionLevel Optimal

$sha256 = [System.Security.Cryptography.SHA256]::Create()
$zipStream = [System.IO.File]::OpenRead($zipPath)
try {
    $hash = [System.BitConverter]::ToString(
        $sha256.ComputeHash($zipStream)
    ).Replace('-', '')
}
finally {
    $zipStream.Dispose()
    $sha256.Dispose()
}

$checksumLine = "$hash *$releaseName.zip`r`n"
[System.IO.File]::WriteAllText(
    $checksumPath,
    $checksumLine,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "RELEASE PACKAGE: $zipPath"
Write-Host "SHA256SUMS     : $checksumPath"
