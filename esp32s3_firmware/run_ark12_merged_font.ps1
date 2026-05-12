param(
    [switch]$UploadFirmware,
    [switch]$UploadFS,
    [string]$UploadPort = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Step([string]$Message) {
    Write-Host "[ark12-clean] $Message"
}

function Test-Command([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-PlatformIoTarget([string]$Target) {
    if (-not (Test-Command "pio")) {
        throw "PlatformIO command 'pio' was not found. Install PlatformIO or omit upload flags."
    }
    $args = @("run", "-t", $Target)
    if ($UploadPort.Trim().Length -gt 0) { $args += @("--upload-port", $UploadPort.Trim()) }
    Write-Step "running: pio $($args -join ' ')"
    & pio @args
    if ($LASTEXITCODE -ne 0) { throw "PlatformIO target '$Target' failed with exit code $LASTEXITCODE" }
}

$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ProjectDir

$FontDir = Join-Path $ProjectDir "data\resources\fonts"
$ArkJson = Join-Path $FontDir "ark12.json"
$ZhTwWoff2 = Join-Path $FontDir "ark12_zh_tw.woff2"
$ZhCnWoff2 = Join-Path $FontDir "ark12_zh_cn.woff2"
$JaWoff2 = Join-Path $FontDir "ark12_ja.woff2"
$IndexHtml = Join-Path $ProjectDir "data\index.html"

$required = @($ArkJson, $ZhTwWoff2, $ZhCnWoff2, $JaWoff2, $IndexHtml)
foreach ($path in $required) {
    if (-not (Test-Path $path -PathType Leaf)) { throw "Required runtime Ark12 file missing: $path" }
}

$removed = @(
    (Join-Path $FontDir "ark12_merged_trad_priority.json"),
    (Join-Path $FontDir "ark12.woff2"),
    (Join-Path $FontDir "unifont.woff2"),
    (Join-Path $ProjectDir ".font_cache")
)
foreach ($path in $removed) {
    if (Test-Path $path) { throw "Redundant/duplicate font resource still exists and should be removed: $path" }
}

$json = Get-Content -Raw -Path $ArkJson | ConvertFrom-Json
if ($json.format -ne "rina_ark_pixel_font_bitmap_v1") { throw "Unexpected Ark12 JSON format: $($json.format)" }
$glyphCount = ($json.glyphs.PSObject.Properties | Measure-Object).Count
if ($glyphCount -lt 24000) { throw "Merged Ark12 glyph count is too low: $glyphCount" }
if ($json.mergePolicy.conflictAuthority -ne "zh_tw") { throw "Merged Ark12 conflict authority is not zh_tw" }
$priority = ($json.mergePolicy.priorityLowToHigh -join ",")
if ($priority -ne "zh_cn,ja,zh_tw") { throw "Unexpected Ark12 merge priority: $priority" }
Write-Step "validated single merged LED bitmap font: ark12.json, $glyphCount glyphs, zh_tw priority"

$html = Get-Content -Raw -Path $IndexHtml
$forbiddenRefs = @("unifont.woff2", "GNU Unifont", "ark12_merged_trad_priority.json", "ark12.woff2")
foreach ($ref in $forbiddenRefs) {
    if ($html.Contains($ref)) { throw "data\index.html still references removed font resource: $ref" }
}
$requiredRefs = @("ark12.json", "ark12_zh_tw.woff2", "ark12_zh_cn.woff2", "ark12_ja.woff2", "Ark Pixel 12px ZH TW", "Ark Pixel 12px ZH CN", "Ark Pixel 12px JA")
foreach ($ref in $requiredRefs) {
    if (-not $html.Contains($ref)) { throw "data\index.html is missing required Ark12 reference: $ref" }
}
Write-Step "validated WebUI/input font references: Ark12 only"

if (Test-Command "node") {
    $start = $html.IndexOf("<script>")
    $end = $html.LastIndexOf("</script>")
    if ($start -ge 0 -and $end -gt $start) {
        $script = $html.Substring($start + 8, $end - ($start + 8))
        $tmp = Join-Path $env:TEMP "rinachan_index_inline_check.js"
        Set-Content -Path $tmp -Value $script -Encoding UTF8
        & node --check $tmp
        if ($LASTEXITCODE -ne 0) { throw "data\index.html inline JavaScript syntax check failed" }
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
        Write-Step "validated data\index.html inline JavaScript"
    }
} else {
    Write-Step "node not found; skipped optional inline JavaScript syntax check"
}

if ($UploadFirmware) { Invoke-PlatformIoTarget "upload" }
if ($UploadFS) { Invoke-PlatformIoTarget "uploadfs" }

Write-Step "done"
