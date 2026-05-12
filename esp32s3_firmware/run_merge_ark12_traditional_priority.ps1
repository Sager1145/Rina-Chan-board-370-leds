param(
    [string]$ArkVersion = "2026.05.07",
    [string]$Languages = "zh_cn,ja,zh_tw",
    [switch]$NoDownload
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Step([string]$Message) {
    Write-Host "[ark12-merge] $Message"
}

function Get-PythonCommand {
    $candidates = @("py -3", "python", "python3")
    foreach ($candidate in $candidates) {
        try {
            $cmd = $candidate.Split(" ")[0]
            $args = @()
            if ($candidate.Contains(" ")) { $args = $candidate.Split(" ")[1..($candidate.Split(" ").Count - 1)] }
            & $cmd @args --version *> $null
            if ($LASTEXITCODE -eq 0) { return $candidate }
        } catch {}
    }
    throw "Python 3 was not found. Install Python 3, then run this script again."
}

function Download-IfMissing([string]$Url, [string]$Path, [string]$Label) {
    if (Test-Path $Path) {
        Write-Step "$Label exists: $Path"
        return
    }
    if ($NoDownload) {
        throw "$Label is missing and -NoDownload was specified: $Path"
    }
    Write-Step "downloading $Label..."
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
    } catch {
        if (Test-Path $Path) { Remove-Item -Force $Path }
        throw "Failed to download $Label from $Url. Error: $($_.Exception.Message)"
    }
}

function Expand-ZipClean([string]$ZipPath, [string]$Destination) {
    if (Test-Path $Destination) { Remove-Item -Recurse -Force $Destination }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Expand-Archive -Force -Path $ZipPath -DestinationPath $Destination
}

function Find-Woff2ForLanguage([string]$Root, [string]$Lang) {
    $files = Get-ChildItem -Recurse -Path $Root -Filter *.woff2
    $exact = $files | Where-Object { $_.Name -match "(^|[-_])$([regex]::Escape($Lang))($|[-_.])" } | Select-Object -First 1
    if ($exact) { return $exact.FullName }
    $loose = $files | Where-Object { $_.Name -match $([regex]::Escape($Lang)) } | Select-Object -First 1
    if ($loose) { return $loose.FullName }
    return $null
}

$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CacheDir = Join-Path $ProjectDir ".font_cache"
$BdfZip = Join-Path $CacheDir "ark-pixel-font-12px-monospaced-bdf-v$ArkVersion.zip"
$Woff2Zip = Join-Path $CacheDir "ark-pixel-font-12px-monospaced-otf.woff2-v$ArkVersion.zip"
$BdfExtract = Join-Path $CacheDir "ark12_bdf"
$Woff2Extract = Join-Path $CacheDir "ark12_woff2"
$FontDir = Join-Path $ProjectDir "data\resources\fonts"
$MergedJson = Join-Path $FontDir "ark12_merged_trad_priority.json"
$CanonicalJson = Join-Path $FontDir "ark12.json"
$CanonicalWoff2 = Join-Path $FontDir "ark12.woff2"
$ReportPath = Join-Path $FontDir "ark12_merged_trad_priority_report.txt"
$PythonScript = Join-Path $ProjectDir "tools\build_ark12_merged.py"

$BdfUrl = "https://github.com/TakWolf/ark-pixel-font/releases/download/$ArkVersion/ark-pixel-font-12px-monospaced-bdf-v$ArkVersion.zip"
$Woff2Url = "https://github.com/TakWolf/ark-pixel-font/releases/download/$ArkVersion/ark-pixel-font-12px-monospaced-otf.woff2-v$ArkVersion.zip"

New-Item -ItemType Directory -Force -Path $CacheDir, $FontDir | Out-Null

Download-IfMissing -Url $BdfUrl -Path $BdfZip -Label "Ark 12px monospaced BDF zip"
Download-IfMissing -Url $Woff2Url -Path $Woff2Zip -Label "Ark 12px monospaced WOFF2 zip"

Write-Step "extracting BDF archive..."
Expand-ZipClean -ZipPath $BdfZip -Destination $BdfExtract
Write-Step "extracting WOFF2 archive..."
Expand-ZipClean -ZipPath $Woff2Zip -Destination $Woff2Extract

$PythonCmd = Get-PythonCommand
Write-Step "using Python: $PythonCmd"

$pyParts = $PythonCmd.Split(" ")
$pyExe = $pyParts[0]
$pyArgs = @()
if ($pyParts.Count -gt 1) { $pyArgs = $pyParts[1..($pyParts.Count - 1)] }

& $pyExe @pyArgs $PythonScript --bdf-root $BdfExtract --out $MergedJson --release-version $ArkVersion --languages $Languages
$mergeExit = $LASTEXITCODE
if ($mergeExit -ge 10) {
    throw "Merge failed with exit code $mergeExit."
}
if ($mergeExit -eq 1) {
    Write-Step "merge completed with a warning; check glyph count and source selection above."
} elseif ($mergeExit -eq 2) {
    throw "Merged font was created, but strict sample validation failed. Check missing glyphs above."
}

Copy-Item -Force $MergedJson $CanonicalJson
Write-Step "copied merged bitmap JSON to: $CanonicalJson"

$ZhTwWoff2 = Find-Woff2ForLanguage -Root $Woff2Extract -Lang "zh_tw"
if (-not $ZhTwWoff2) {
    throw "Could not find zh_tw WOFF2 in extracted archive. The bitmap JSON was created, but WebUI font copy failed."
}
Copy-Item -Force $ZhTwWoff2 $CanonicalWoff2
Write-Step "copied traditional-priority WebUI WOFF2 to: $CanonicalWoff2"

$now = Get-Date -Format "yyyy-MM-dd HH:mm:ss K"
$report = @"
Ark Pixel 12px merged font build report
Generated: $now
Release: $ArkVersion
Merge order low -> high priority: $Languages
Conflict authority: zh_tw / Traditional Chinese

Outputs:
- $MergedJson
- $CanonicalJson
- $CanonicalWoff2

Notes:
- ark12.json is the merged bitmap table for firmware/WebUI frame generation.
- ark12.woff2 is copied from the zh_tw official WOFF2 variant so browser-rendered text uses Traditional Chinese forms when regional glyphs differ.
- If the firmware renderer assumes exactly 12 bitmap rows, keep clipping enabled because Ark includes a small number of vertical-form glyphs with more than 12 rows.
"@
Set-Content -Path $ReportPath -Value $report -Encoding UTF8
Write-Step "wrote report: $ReportPath"
Write-Step "done."
