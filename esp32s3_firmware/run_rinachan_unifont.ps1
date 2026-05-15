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

$ProjectDir = (Resolve-Path $PSScriptRoot).Path
$PlatformioIni = Join-Path $ProjectDir "platformio.ini"
$IndexHtml = Join-Path $ProjectDir "data\index.html"
$MainCpp = Join-Path $ProjectDir "src\main.cpp"

if (-not (Test-Path $PlatformioIni) -or -not (Test-Path $IndexHtml) -or -not (Test-Path $MainCpp)) {
    throw "This script must be run from inside the extracted esp32s3_firmware project folder."
}

Write-Host "[run] project root: $ProjectDir"

function Write-Step([string]$Message) {
    Write-Host "[run] $Message"
}

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

function Expand-ZipClean([string]$ZipPath, [string]$Destination) {
    if (Test-Path $Destination) { Remove-Item -Recurse -Force $Destination }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Expand-Archive -Force -Path $ZipPath -DestinationPath $Destination
}

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
        ("gnu_" + "unifont_17_0_04_webui_subset.woff2")
    )
    foreach ($Name in $LegacyNames) {
        $Path = Join-Path $FontDir $Name
        if (Test-Path $Path) {
            Write-Host "[font] removing redundant font resource: $Path"
            Remove-Item -Force $Path
        }
    }
}

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

function Find-Woff2ForLanguage([string]$Root, [string]$Lang) {
    $files = @(Get-ChildItem -Recurse -Path $Root -Filter *.woff2 -ErrorAction SilentlyContinue)
    $escaped = [regex]::Escape($Lang)
    $exact = $files | Where-Object { $_.Name -match "(^|[-_])$escaped($|[-_.])" } | Sort-Object FullName | Select-Object -First 1
    if ($exact) { return $exact.FullName }
    $loose = $files | Where-Object { $_.Name -match $escaped } | Sort-Object FullName | Select-Object -First 1
    if ($loose) { return $loose.FullName }
    return $null
}

function Test-MergedArk12Json([string]$Path) {
    if (-not (Test-Path $Path)) { return $false }
    try {
        $json = Get-Content -Raw -Encoding UTF8 -Path $Path | ConvertFrom-Json
        if ($json.format -ne "rina_ark_pixel_font_bitmap_v1") { return $false }
        if (-not $json.mergePolicy) { return $false }
        $order = @($json.mergePolicy.priorityLowToHigh)
        if (($order -join ",") -ne "zh_cn,ja,zh_tw") { return $false }
        if ($json.mergePolicy.conflictAuthority -ne "zh_tw") { return $false }
        $glyphProps = @($json.glyphs.PSObject.Properties)
        if ($glyphProps.Count -lt 24000) { return $false }
        $glyphNames = @($json.glyphs.PSObject.Properties.Name)
        foreach ($cp in @("4F60", "597D", "7E41", "9AD4", "65E5", "672C", "8A9E", "3053", "3093", "306B", "3061", "306F", "7483", "5948")) {
            if ($glyphNames -notcontains $cp) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

function Build-UnifontWebFont([string]$UnifontWebFont, [string]$CacheDir) {
    $Python = Get-PythonCommand
    Ensure-PythonFontModules $Python

    $UnifontPng = Join-Path $CacheDir "unifont-$UnifontVersion.png"
    $UnifontPngUrl = "https://ftp.gnu.org/gnu/unifont/unifont-$UnifontVersion/unifont-$UnifontVersion.png"
    $UnifontTool = Join-Path $ProjectDir "tools\build_unifont_webui_subset_from_png.py"

    if (-not (Test-Path $UnifontTool)) {
        throw "Missing GNU Unifont WebUI subset build tool: $UnifontTool"
    }

    Download-IfMissing -Url $UnifontPngUrl -Path $UnifontPng -Label "GNU Unifont $UnifontVersion BMP PNG sheet"

    Write-Host "[font] building WebUI GNU Unifont subset: $UnifontWebFont"
    Invoke-PythonChecked $Python @($UnifontTool, "--png", $UnifontPng, "--out", $UnifontWebFont, "--version", $UnifontVersion, "--embed-index", $IndexHtml) "GNU Unifont WebUI subset build failed."

    if (-not (Test-Path $UnifontWebFont)) {
        throw "GNU Unifont WebUI subset was not generated: $UnifontWebFont"
    }
    $size = (Get-Item $UnifontWebFont).Length
    if ($size -lt 10000) {
        throw "Generated GNU Unifont WebUI subset is suspiciously small: $size bytes"
    }
    Write-Host "[font] generated WebUI GNU Unifont subset: $UnifontWebFont ($size bytes)"
}

function Ensure-UnifontWebFont([string]$UnifontWebFont, [string]$CacheDir) {
    Write-Host "[font] synchronizing embedded WebUI GNU Unifont subset with current WebUI text..."
    if (Test-Path $UnifontWebFont) {
        $size = (Get-Item $UnifontWebFont).Length
        if ($size -lt 10000) {
            Write-Host "[font] existing GNU Unifont WebUI file is too small; rebuilding: $UnifontWebFont" -ForegroundColor Yellow
            Remove-Item -Force $UnifontWebFont
        }
    }
    Build-UnifontWebFont -UnifontWebFont $UnifontWebFont -CacheDir $CacheDir
}

function Prepare-FontResources {
    $FontDir = Join-Path $ProjectDir "data\resources\fonts"
    $CacheDir = Join-Path $ProjectDir ".font_cache"
    $BdfZip = Join-Path $CacheDir "ark-pixel-font-12px-monospaced-bdf-v$ArkVersion.zip"
    $Woff2Zip = Join-Path $CacheDir "ark-pixel-font-12px-monospaced-otf.woff2-v$ArkVersion.zip"
    $BdfExtract = Join-Path $CacheDir "ark12_bdf_tmp"
    $Woff2Extract = Join-Path $CacheDir "ark12_woff2_tmp"
    $CompiledJson = Join-Path $FontDir "ark12.json"
    $ArkWebFont = Join-Path $FontDir "ark12.woff2"
    $UnifontWebFont = Join-Path $FontDir "unifont.woff2"
    $MergeTool = Join-Path $ProjectDir "tools\build_ark12_merged.py"

    New-Item -ItemType Directory -Force -Path $FontDir, $CacheDir | Out-Null
    Remove-LegacyFontResources $FontDir
    Remove-RedundantFontCache $CacheDir

    Ensure-UnifontWebFont -UnifontWebFont $UnifontWebFont -CacheDir $CacheDir

    if ((Test-Path $ArkWebFont) -and (Test-MergedArk12Json $CompiledJson)) {
        Write-Host "[font] existing merged Ark12 text-scroll resources found; no rebuild required."
        Get-Item $UnifontWebFont, $ArkWebFont, $CompiledJson -ErrorAction SilentlyContinue | Format-Table Name, Length
        return
    }

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
    Get-Item $UnifontWebFont, $ArkWebFont, $CompiledJson -ErrorAction SilentlyContinue | Format-Table Name, Length
}

function Assert-RequiredFontResources {
    $FontDir = Join-Path $ProjectDir "data\resources\fonts"
    $Required = @(
        (Join-Path $FontDir "unifont.woff2"),
        (Join-Path $FontDir "ark12.woff2"),
        (Join-Path $FontDir "ark12.json")
    )
    $Missing = @($Required | Where-Object { -not (Test-Path $_) })
    if ($Missing.Count -gt 0) {
        Write-Host "[font] missing required LittleFS font resources:" -ForegroundColor Yellow
        $Missing | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        throw "Required font resources are missing. Re-run without -SkipPrepareFonts before uploadfs."
    }
    Write-Host "[font] required LittleFS font resources are present."
}

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
        pio run -t upload
    }
    if ($UploadFS) {
        Write-Host "[run] uploading LittleFS..."
        pio run -t uploadfs
    }
    if (-not $UploadFirmware -and -not $UploadFS) {
        Write-Host "[run] no upload switch supplied; running PlatformIO build only..."
        pio run
        Write-Host "[run] build complete. Use -UploadFirmware and/or -UploadFS to upload."
    }
} finally {
    Pop-Location
}
