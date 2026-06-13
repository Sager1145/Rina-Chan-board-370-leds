# 中文文件说明：本脚本自动准备字体、资源、构建和上传固件/文件系统；PowerShell 参数和命令名保持 English。
param(
    [switch]$UploadFirmware,
    [switch]$UploadFS,
    [switch]$SkipPrepareFonts,
    [switch]$NoDownload,
    [string]$ArkVersion = "2026.05.07",
    [string]$ArkLanguages = "zh_cn,ja,zh_tw",
    [string]$UnifontVersion = "17.0.04"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$env:PYTHONIOENCODING = "utf-8"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$ProjectDir = (Resolve-Path $PSScriptRoot).Path
$PlatformioIni = Join-Path $ProjectDir "platformio.ini"
$IndexHtml = Join-Path $ProjectDir "data\index.html"
$StylesCss = Join-Path $ProjectDir "data\styles.css"
$AppJs = Join-Path $ProjectDir "data\app.js"
$MainCpp = Join-Path $ProjectDir "src\main.cpp"

if (-not (Test-Path $PlatformioIni) -or -not (Test-Path $IndexHtml) -or -not (Test-Path $StylesCss) -or -not (Test-Path $AppJs) -or -not (Test-Path $MainCpp)) {
    throw "This script must be run from inside the extracted esp32s3_firmware project folder."
}

Write-Host "[run] project root: $ProjectDir"

# 中文块：Write-Step 负责输出状态或文件内容，是构建/上传流程中的一个步骤。
function Write-Step([string]$Message) {
    Write-Host "[run] $Message"
}

# 中文块：Get-PythonCommand 负责取得路径、命令或配置值，供后续步骤使用。
function Get-PythonCommand {
    $candidates = @(
        [pscustomobject]@{Exe="py"; Args=@("-3")},
        [pscustomobject]@{Exe="python"; Args=@()},
        [pscustomobject]@{Exe="python3"; Args=@()}
    )
    foreach ($candidate in $candidates) {
        try {
            & $candidate.Exe @($candidate.Args) --version *> $null
            if ($LASTEXITCODE -eq 0) { return $candidate }
        } catch {}
    }
    throw "Python 3 was not found. Install Python 3, then run this script again."
}

# 中文块：Invoke-PythonChecked 封装构建/上传流程中的一个独立步骤。
function Invoke-PythonChecked($Python, [string[]]$ExtraArgs, [string]$ErrorMessage) {
    $allArgs = @()
    $allArgs += @($Python.Args)
    $allArgs += @($ExtraArgs)
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Python.Exe @allArgs
        $exit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldEap
    }
    if ($exit -ne 0) { throw $ErrorMessage }
}

# 中文块：Invoke-PythonTempScript 封装构建/上传流程中的一个独立步骤。
function Invoke-PythonTempScript($Python, [string]$Code, [string[]]$Arguments) {
    $TempScript = Join-Path ([System.IO.Path]::GetTempPath()) ("rinachan_py_probe_{0}.py" -f ([System.Guid]::NewGuid().ToString("N")))
    try {
        Set-Content -Path $TempScript -Value $Code -Encoding UTF8
        $allArgs = @()
        $allArgs += @($Python.Args)
        $allArgs += @($TempScript)
        $allArgs += @($Arguments)
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $out = & $Python.Exe @allArgs 2>&1
            $exit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldEap
        }
        return [pscustomobject]@{ ExitCode = $exit; Output = @($out) }
    } finally {
        Remove-Item -Force -Path $TempScript -ErrorAction SilentlyContinue
    }
}

# 中文块：Test-PythonModules 封装构建/上传流程中的一个独立步骤。
function Test-PythonModules($Python, [string[]]$ImportNames) {
    $code = @'
import importlib.util
import sys
missing = [name for name in sys.argv[1:] if importlib.util.find_spec(name) is None]
if missing:
    print(",".join(missing))
    raise SystemExit(1)
raise SystemExit(0)
'@
    $result = Invoke-PythonTempScript -Python $Python -Code $code -Arguments $ImportNames
    if ($result.ExitCode -eq 0) { return $true }
    $outputText = (($result.Output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ($outputText) {
        if ($outputText -match "^[A-Za-z0-9_.,-]+$") {
            Write-Host "[font] missing Python module(s): $outputText" -ForegroundColor Yellow
        } else {
            Write-Host "[font] Python module probe failed:" -ForegroundColor Yellow
            Write-Host $outputText -ForegroundColor Yellow
        }
    }
    return $false
}

# 中文块：Ensure-PythonFontModules 负责检查并补齐运行前置条件。
function Ensure-PythonFontModules($Python) {
    $imports = @("PIL", "fontTools", "brotli")
    if (Test-PythonModules $Python $imports) {
        Write-Host "[font] Python font build modules are present."
        return
    }
    if ($NoDownload) {
        throw "Python font build modules are missing and -NoDownload was specified. Required pip packages: pillow fonttools brotli"
    }

    Write-Host "[font] installing Python font build modules: pillow fonttools brotli"
    Invoke-PythonChecked $Python @("-m", "pip", "install", "--user", "--upgrade", "pillow", "fonttools", "brotli") "Failed to install Python font build modules."
    if (-not (Test-PythonModules $Python $imports)) {
        throw "Python font build modules are still missing after pip install. Required packages: pillow fonttools brotli"
    }
}

# 中文块：Download-IfMissing 负责在缺失时下载所需资源。
function Download-IfMissing([string]$Url, [string]$Path, [string]$Label) {
    if (Test-Path $Path) {
        Write-Host "[font] $Label exists: $Path"
        return
    }
    if ($NoDownload) {
        throw "$Label is missing and -NoDownload was specified: $Path"
    }
    Write-Host "[font] downloading $Label..."
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
    } catch {
        if (Test-Path $Path) { Remove-Item -Force $Path }
        throw "Failed to download $Label from $Url. Error: $($_.Exception.Message)"
    }
}

# 中文块：Expand-ZipClean 封装构建/上传流程中的一个独立步骤。
function Expand-ZipClean([string]$ZipPath, [string]$Destination) {
    if (Test-Path $Destination) { Remove-Item -Recurse -Force $Destination }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Expand-Archive -Force -Path $ZipPath -DestinationPath $Destination
}

# 中文块：Remove-LegacyFontResources 封装构建/上传流程中的一个独立步骤。
function Remove-LegacyFontResources([string]$FontDir) {
    $OldPrefix = ("u" + "8" + "g" + "2")
    $LegacyNames = @(
        "$($OldPrefix)_16.woff2",
        "rina_$($OldPrefix)_16_webui_20260511.woff2",
        "rina_$($OldPrefix)_16_webui_20260511.ttf",
        "ark-pixel-font-12px-monospaced.otf.woff2",
        "ark-pixel-font-12px-monospaced.rinafont.json",
        "ark12_merged_trad_priority.json",
        "ark12_merged_trad_priority_report.txt",
        ("gnu_" + "unifont_17_0_04_webui_subset.woff2"),
        "ark12_fallback.woff2"
        # 注意：unifont.woff2 现在是独立 WebUI 字体资源，由 Build-AndEmbedUnifontWebFont
        # 生成并被 styles.css 引用，绝不能当作 legacy 删除。
    )
    foreach ($Name in $LegacyNames) {
        $Path = Join-Path $FontDir $Name
        if (Test-Path $Path) {
            Write-Host "[font] removing redundant font resource: $Path"
            Remove-Item -Force $Path
        }
    }
}

# 中文块：Remove-RedundantFontCache 封装构建/上传流程中的一个独立步骤。
function Remove-RedundantFontCache([string]$CacheDir) {
    $RedundantDirs = @(
        "ark12_bdf",
        "ark12_woff2",
        "bdf",
        "woff2",
        "ark12_bdf_tmp",
        "ark12_woff2_tmp"
    )
    foreach ($Name in $RedundantDirs) {
        $Path = Join-Path $CacheDir $Name
        if (Test-Path $Path) {
            Write-Host "[font] removing redundant extracted cache directory: $Path"
            Remove-Item -Recurse -Force -Path $Path
        }
    }
}

# 中文块：Find-Woff2ForLanguage 负责查找构建/上传流程需要的资源。
function Find-Woff2ForLanguage([string]$Root, [string]$Lang) {
    $files = @(Get-ChildItem -Recurse -Path $Root -Filter *.woff2 -ErrorAction SilentlyContinue)
    $escaped = [regex]::Escape($Lang)
    $exact = $files | Where-Object { $_.Name -match "(^|[-_])$escaped($|[-_.])" } | Sort-Object FullName | Select-Object -First 1
    if ($exact) { return $exact.FullName }
    $loose = $files | Where-Object { $_.Name -match $escaped } | Sort-Object FullName | Select-Object -First 1
    if ($loose) { return $loose.FullName }
    return $null
}

# 中文块：Test-MergedArk12Json 封装构建/上传流程中的一个独立步骤。
function Test-MergedArk12Json([string]$Path) {
    # 中文说明：说明字体、字形、Unicode 范围或 Web font 资源处理。
    # 中文说明：说明字体、字形、Unicode 范围或 Web font 资源处理。
    # 中文说明：说明字体、字形、Unicode 范围或 Web font 资源处理。
    if (-not (Test-Path $Path)) { return $false }
    try {
        $json = Get-Content -Raw -Encoding UTF8 -Path $Path | ConvertFrom-Json
        if ($json.format -ne "rina_ark_pixel_font_bitmap_v1") { return $false }
        if ([int]$json.rows -ne 12) { return $false }
        if ([int]$json.lineHeight -ne 12) { return $false }
        if ([int]$json.defaultAdvance -ne 12) { return $false }
        if (-not $json.mergePolicy) { return $false }
        $order = @($json.mergePolicy.priorityLowToHigh)
        if (($order -join ",") -ne "zh_cn,ja,zh_tw") { return $false }
        if ($json.mergePolicy.conflictAuthority -ne "zh_tw") { return $false }
        $glyphProps = @($json.glyphs.PSObject.Properties)
        if ($glyphProps.Count -lt 32000) { return $false }
        $glyphNames = @($json.glyphs.PSObject.Properties.Name)
        foreach ($cp in @("7136", "71C3", "6EDA", "6EFE")) {
            if ($glyphNames -notcontains $cp) { return $false }
            $g = $json.glyphs.$cp
            if ($null -eq $g -or $g.Count -lt 7) { return $false }
            if ([int]$g[1] -ne 12) { return $false }
            $rows = ([string]$g[6]).Split('/')
            if ($rows.Count -ne 12) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

# 中文块：Install-BundledArk12FusionResources 封装构建/上传流程中的一个独立步骤。
function Install-BundledArk12FusionResources([string]$FontDir) {
    $FusionDir = Join-Path $ProjectDir "tools\font_fusion"
    $BundledJson = Join-Path $FusionDir "ark12_fusion.json"
    $BundledBaseWoff2 = Join-Path $FusionDir "ark12_base.woff2"
    foreach ($Path in @($BundledJson, $BundledBaseWoff2)) {
        if (-not (Test-Path $Path)) {
            throw "Bundled Ark12 fusion resource is missing: $Path"
        }
    }
    Copy-Item -Force $BundledJson (Join-Path $FontDir "ark12.json")
    Copy-Item -Force $BundledBaseWoff2 (Join-Path $FontDir "ark12.woff2")
    # 中文说明：说明字体、字形、Unicode 范围或 Web font 资源处理。
    # 中文说明：说明字体、字形、Unicode 范围或 Web font 资源处理。
    $LegacyFallback = Join-Path $FontDir "ark12_fallback.woff2"
    if (Test-Path $LegacyFallback) {
        Write-Host "[font] removing obsolete split fallback font: $LegacyFallback"
        Remove-Item -Force $LegacyFallback
    }
    if (-not (Test-MergedArk12Json (Join-Path $FontDir "ark12.json"))) {
        throw "Bundled Ark12 fusion JSON validation failed after copy."
    }
    Write-Host "[font] installed bundled Ark12 fusion resources (single merged woff2 incl. 然 / 燃 / 滚 / 滾 + Mona12 emoji)."
}

# 中文块：Build-AndEmbedUnifontWebFont 负责生成构建流程需要的资源。
function Build-AndEmbedUnifontWebFont([string]$CacheDir) {
    $Python = Get-PythonCommand
    Ensure-PythonFontModules $Python

    $UnifontPng = Join-Path $CacheDir "unifont-$UnifontVersion.png"
    $UnifontPngUrl = "https://ftp.gnu.org/gnu/unifont/unifont-$UnifontVersion/unifont-$UnifontVersion.png"
    $UnifontTool = Join-Path $ProjectDir "tools\build_unifont_webui_subset_from_png.py"
    $FontDir = Join-Path $ProjectDir "data\resources\fonts"
    $OutUnifont = Join-Path $FontDir "unifont.woff2"
    $UnifontHref = "/resources/fonts/unifont.woff2?v=$UnifontVersion-webui"

    if (-not (Test-Path $UnifontTool)) {
        throw "Missing GNU Unifont WebUI subset build tool: $UnifontTool"
    }

    Download-IfMissing -Url $UnifontPngUrl -Path $UnifontPng -Label "GNU Unifont $UnifontVersion BMP PNG sheet"

    Write-Host "[font] building standalone WebUI GNU Unifont subset -> $OutUnifont (referenced by styles.css)..."
    if (-not (Test-Path $FontDir)) { New-Item -ItemType Directory -Force -Path $FontDir | Out-Null }
    Invoke-PythonChecked $Python @($UnifontTool, "--png", $UnifontPng, "--out", $OutUnifont, "--version", $UnifontVersion, "--external-css", $StylesCss, "--external-href", $UnifontHref, "--text-file", $IndexHtml, "--text-file", $StylesCss, "--text-file", $AppJs, "--text-file", (Join-Path $ProjectDir "data\resources\saved_faces.json"), "--text-file", (Join-Path $ProjectDir "data\resources\runtime_settings.json"), "--text-file", (Join-Path $ProjectDir "data\resources\battery_calib.json")) "GNU Unifont WebUI subset build failed."

    if (-not (Test-Path $OutUnifont)) {
        throw "Standalone GNU Unifont WebUI subset was not generated: $OutUnifont"
    }
    $size = (Get-Item $OutUnifont).Length
    if ($size -lt 10000) {
        throw "Generated GNU Unifont WebUI subset is suspiciously small: $size bytes"
    }

    Write-Host "[font] wrote standalone LittleFS unifont.woff2 ($size bytes); styles.css references it via url()."
}

# 中文块：Ensure-EmbeddedUnifontWebFont 负责检查并补齐运行前置条件。
function Ensure-EmbeddedUnifontWebFont([string]$CacheDir) {
    Write-Host "[font] synchronizing standalone WebUI GNU Unifont subset with current WebUI text..."
    Build-AndEmbedUnifontWebFont -CacheDir $CacheDir
}

# 中文块：Prepare-FontResources 封装构建/上传流程中的一个独立步骤。
function Prepare-FontResources {
    $FontDir = Join-Path $ProjectDir "data\resources\fonts"
    $CacheDir = Join-Path $ProjectDir ".font_cache"
    $BdfZip = Join-Path $CacheDir "ark-pixel-font-12px-monospaced-bdf-v$ArkVersion.zip"
    $Woff2Zip = Join-Path $CacheDir "ark-pixel-font-12px-monospaced-otf.woff2-v$ArkVersion.zip"
    $BdfExtract = Join-Path $CacheDir "ark12_bdf_tmp"
    $Woff2Extract = Join-Path $CacheDir "ark12_woff2_tmp"
    $CompiledJson = Join-Path $FontDir "ark12.json"
    $ArkWebFont = Join-Path $FontDir "ark12.woff2"
    $MergeTool = Join-Path $ProjectDir "tools\build_ark12_merged.py"

    New-Item -ItemType Directory -Force -Path $FontDir, $CacheDir | Out-Null
    Remove-LegacyFontResources $FontDir
    Remove-RedundantFontCache $CacheDir

    Ensure-EmbeddedUnifontWebFont -CacheDir $CacheDir

    if ((Test-Path $ArkWebFont) -and (Test-MergedArk12Json $CompiledJson)) {
        Write-Host "[font] existing fused Ark12 text-scroll resources found; no rebuild required."
        Get-Item $ArkWebFont, $CompiledJson -ErrorAction SilentlyContinue | Format-Table Name, Length
        return
    }

    Write-Host "[font] fused Ark12 resources are missing or stale; installing bundled fusion files."
    Install-BundledArk12FusionResources -FontDir $FontDir
    Get-Item $ArkWebFont, $CompiledJson -ErrorAction SilentlyContinue | Format-Table Name, Length
    return

    if (-not (Test-Path $MergeTool)) {
        throw "Missing Ark12 merge tool: $MergeTool"
    }

    $BdfUrl = "https://github.com/TakWolf/ark-pixel-font/releases/download/$ArkVersion/ark-pixel-font-12px-monospaced-bdf-v$ArkVersion.zip"
    $Woff2Url = "https://github.com/TakWolf/ark-pixel-font/releases/download/$ArkVersion/ark-pixel-font-12px-monospaced-otf.woff2-v$ArkVersion.zip"

    Download-IfMissing -Url $BdfUrl -Path $BdfZip -Label "Ark 12px monospaced BDF zip"
    Download-IfMissing -Url $Woff2Url -Path $Woff2Zip -Label "Ark 12px monospaced WOFF2 zip"

    try {
        Write-Host "[font] extracting Ark BDF archive..."
        Expand-ZipClean -ZipPath $BdfZip -Destination $BdfExtract
        Write-Host "[font] extracting Ark WOFF2 archive..."
        Expand-ZipClean -ZipPath $Woff2Zip -Destination $Woff2Extract

        $Python = Get-PythonCommand
        Write-Host "[font] using Python: $($Python.Exe) $($Python.Args -join ' ')"
        Invoke-PythonChecked $Python @($MergeTool, "--bdf-root", $BdfExtract, "--out", $CompiledJson, "--release-version", $ArkVersion, "--languages", $ArkLanguages) "Merged Ark12 build failed."

        $ZhTwWoff2 = Find-Woff2ForLanguage -Root $Woff2Extract -Lang "zh_tw"
        if (-not $ZhTwWoff2) {
            throw "Could not find zh_tw WOFF2 in extracted Ark archive."
        }
        Copy-Item -Force $ZhTwWoff2 $ArkWebFont
        Write-Host "[font] copied text-scroll browser font with Traditional priority: $ArkWebFont"
    } finally {
        Remove-Item -Recurse -Force -Path $BdfExtract, $Woff2Extract -ErrorAction SilentlyContinue
    }

    if (-not (Test-MergedArk12Json $CompiledJson)) {
        throw "Merged Ark12 JSON validation failed: $CompiledJson"
    }

    Write-Host "[font] final LittleFS font resources:"
    Get-Item $ArkWebFont, $CompiledJson -ErrorAction SilentlyContinue | Format-Table Name, Length
}


# 中文块：Sync-WebAssetGzipFiles 负责同步临时资源与源文件状态。
function Sync-WebAssetGzipFiles {
    $Python = Get-PythonCommand
    $code = @'
import gzip
import pathlib
import shutil
import sys
for arg in sys.argv[1:]:
    src = pathlib.Path(arg)
    if not src.exists():
        print(f"missing web asset: {src}")
        raise SystemExit(1)
    dst = src.with_name(src.name + ".gz")
    with src.open("rb") as fin, gzip.GzipFile(filename="", mode="wb", fileobj=dst.open("wb"), mtime=0) as fout:
        shutil.copyfileobj(fin, fout)
    raw = src.read_bytes()
    dec = gzip.decompress(dst.read_bytes())
    if raw != dec:
        print(f"gzip verification failed: {src}")
        raise SystemExit(1)
    print(f"gzipped {src.name} -> {dst.name} ({len(raw)} bytes)")
'@
    $assets = Get-WebAssetSourcePaths
    $result = Invoke-PythonTempScript -Python $Python -Code $code -Arguments $assets
    $outputText = (($result.Output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ($outputText) { Write-Host $outputText }
    if ($result.ExitCode -ne 0) {
        throw "Failed to synchronize gzip web assets."
    }
}

# 中文块：Get-WebAssetSourcePaths 负责取得路径、命令或配置值，供后续步骤使用。
function Get-WebAssetSourcePaths {
    $AppJs = Join-Path $ProjectDir "data\app.js"
    return @(
        $IndexHtml,
        $AppJs,
        $StylesCss,
        (Join-Path $ProjectDir "data\resources\fonts\ark12.json")
    )
}

# 中文块：Get-WebAssetGzipPaths 负责取得路径、命令或配置值，供后续步骤使用。
function Get-WebAssetGzipPaths {
    return @(Get-WebAssetSourcePaths | ForEach-Object { "$_.gz" })
}

# 中文块：Remove-WebAssetGzipFiles 封装构建/上传流程中的一个独立步骤。
function Remove-WebAssetGzipFiles {
    $DataDir = Join-Path $ProjectDir "data"
    $removed = @()
    foreach ($Path in Get-WebAssetGzipPaths) {
        if (Test-Path $Path) {
            $resolved = (Resolve-Path -LiteralPath $Path).Path
            $relative = $resolved
            if ($resolved.StartsWith($DataDir, [System.StringComparison]::OrdinalIgnoreCase)) {
                $relative = $resolved.Substring($DataDir.Length).TrimStart("\")
            }
            Remove-Item -Force -LiteralPath $Path
            $removed += $relative
        }
    }
    if ($removed.Count -gt 0) {
        Write-Host "[gzip] removed temporary LittleFS gzip assets:"
        $removed | ForEach-Object { Write-Host ("  " + $_) }
    } else {
        Write-Host "[gzip] no temporary LittleFS gzip assets to remove."
    }
}

# 中文块：Invoke-PlatformIoChecked 封装构建/上传流程中的一个独立步骤。
function Invoke-PlatformIoChecked([string[]]$Arguments, [string]$ErrorMessage) {
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & pio @Arguments
        $exit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldEap
    }
    if ($exit -ne 0) { throw $ErrorMessage }
}

# 中文块：Assert-EmbeddedUnifontWebUi 封装构建/上传流程中的一个独立步骤。
function Assert-EmbeddedUnifontWebUi {
    $Python = Get-PythonCommand
    $code = @'
import hashlib
import pathlib
import re
import sys

index_path = pathlib.Path(sys.argv[1])
css_path = pathlib.Path(sys.argv[2])
project_dir = pathlib.Path(sys.argv[3])
html = index_path.read_text(encoding="utf-8")
css = css_path.read_text(encoding="utf-8")
block_re = re.compile(r"@font-face\s*\{(?=[^{}]*font-family\s*:\s*['\"]GNU Unifont['\"])[^{}]*\}", re.S)
blocks = block_re.findall(css)
if len(blocks) != 1:
    print(f"expected exactly one GNU Unifont @font-face block, found {len(blocks)}")
    raise SystemExit(1)
block = blocks[0]
if "data:font/woff2;base64," in block:
    print("GNU Unifont @font-face must NOT embed a base64 data URL anymore")
    raise SystemExit(1)
if not re.search(r"url\(\s*['\"]?/resources/fonts/unifont\.woff2", block):
    print("GNU Unifont @font-face must reference /resources/fonts/unifont.woff2 via url()")
    raise SystemExit(1)
font_path = project_dir / "data" / "resources" / "fonts" / "unifont.woff2"
if not font_path.exists():
    print(f"standalone WebUI Unifont resource is missing: {font_path}")
    raise SystemExit(1)
data = font_path.read_bytes()
if data[:4] != b"wOF2":
    print("standalone unifont.woff2 is not a valid WOFF2 (bad magic)")
    raise SystemExit(1)
if len(data) < 10000:
    print(f"standalone GNU Unifont is suspiciously small: {len(data)} bytes")
    raise SystemExit(1)
compact_css = re.sub(r"\s+", "", css)
styles_link_re = re.compile(
    r"<link\b(?=[^>]*\brel=['\"]stylesheet['\"])(?=[^>]*\bhref=['\"]styles\.css(?:\?[^'\"]*)?['\"])[^>]*>",
    re.I,
)
if not styles_link_re.search(html):
    print('index.html does not link styles.css')
    raise SystemExit(1)
preload_re = re.compile(
    r"<link\b(?=[^>]*\brel=['\"]preload['\"])(?=[^>]*\bas=['\"]font['\"])(?=[^>]*href=['\"][^'\"]*?/resources/fonts/unifont\.woff2)[^>]*>",
    re.I,
)
if not preload_re.search(html):
    print('index.html must <link rel=preload as=font> the standalone unifont.woff2')
    raise SystemExit(1)
if '--ui-font:"GNUUnifont"' not in compact_css:
    print('CSS variable --ui-font is not pinned to "GNU Unifont"')
    raise SystemExit(1)
print(hashlib.sha256(data).hexdigest())
'@
    $result = Invoke-PythonTempScript -Python $Python -Code $code -Arguments @($IndexHtml, $StylesCss, $ProjectDir)
    $outputText = (($result.Output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ($result.ExitCode -ne 0) {
        if ($outputText) { Write-Host $outputText -ForegroundColor Yellow }
        throw "Standalone GNU Unifont WebUI validation failed."
    }
    Write-Host "[font] standalone GNU Unifont validated sha256=$outputText"
}

# 中文块：Assert-RequiredFontResources 封装构建/上传流程中的一个独立步骤。
function Assert-RequiredFontResources {
    $FontDir = Join-Path $ProjectDir "data\resources\fonts"
    $Required = @(
        (Join-Path $FontDir "ark12.woff2"),
        (Join-Path $FontDir "ark12.json")
    )
    $Missing = @($Required | Where-Object { -not (Test-Path $_) })
    if ($Missing.Count -gt 0) {
        Write-Host "[font] missing required LittleFS font resources:" -ForegroundColor Yellow
        $Missing | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        throw "Required font resources are missing. Re-run without -SkipPrepareFonts before uploadfs."
    }
    if (-not (Test-MergedArk12Json (Join-Path $FontDir "ark12.json"))) {
        throw "Fused Ark12 JSON validation failed. Required patched glyphs include 然 / 燃 / 滚 / 滾. Re-run without -SkipPrepareFonts."
    }
    Assert-EmbeddedUnifontWebUi
    Write-Host "[font] required LittleFS font resources are present. WebUI Unifont is embedded in styles.css only."
}

# 中文块：Assert-LittleFSNameLengths 封装构建/上传流程中的一个独立步骤。
function Assert-LittleFSNameLengths {
    $DataDir = Join-Path $ProjectDir "data"
    $TooLong = Get-ChildItem -Recurse -Force -Path $DataDir | Where-Object { $_.Name.Length -gt 31 }
    if ($TooLong) {
        Write-Host "[littlefs] file or directory names longer than 31 characters may fail in mklittlefs:" -ForegroundColor Yellow
        $TooLong | Select-Object FullName, @{Name="NameLength"; Expression={$_.Name.Length}} | Format-Table -AutoSize
        throw "Rename the listed LittleFS files/directories to 31 characters or fewer before uploadfs."
    }
    Write-Host "[littlefs] all LittleFS file/directory names are <= 31 characters."
}

if (-not $SkipPrepareFonts) {
    Prepare-FontResources
} else {
    Write-Step "skipping font preparation by request."
}

Assert-RequiredFontResources
Assert-LittleFSNameLengths

Push-Location $ProjectDir
try {
    if ($UploadFirmware) {
        Write-Host "[run] uploading firmware and partition table..."
        Invoke-PlatformIoChecked @("run", "-t", "upload") "Firmware upload failed."
    }
    if ($UploadFS) {
        Sync-WebAssetGzipFiles
        Write-Host "[run] uploading LittleFS..."
        Invoke-PlatformIoChecked @("run", "-t", "uploadfs") "LittleFS upload failed."
    }
    if (-not $UploadFirmware -and -not $UploadFS) {
        Write-Host "[run] no upload switch supplied; running PlatformIO build only..."
        Invoke-PlatformIoChecked @("run") "PlatformIO build failed."
        Write-Host "[run] build complete. Use -UploadFirmware and/or -UploadFS to upload."
    }
} finally {
    Pop-Location
    Remove-WebAssetGzipFiles
}
