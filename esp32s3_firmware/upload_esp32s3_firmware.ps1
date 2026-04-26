param(
    [string]$ZipPath = ".\esp32s3_firmware_play_stop_before_upload_fix.zip",
    [string]$Port = "auto",
    [switch]$InstallMpremote,
    [switch]$NoClean
)

$ErrorActionPreference = "Stop"

function Write-Step($Text) {
    Write-Host "[ESP32S3] $Text"
}

function Find-PythonLauncher {
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) { return @($py.Source) }
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) { return @($python.Source) }
    $python3 = Get-Command python3 -ErrorAction SilentlyContinue
    if ($python3) { return @($python3.Source) }
    return $null
}

$MpremoteExe = Get-Command mpremote -ErrorAction SilentlyContinue
$PythonLauncher = Find-PythonLauncher

if (-not $MpremoteExe -and $InstallMpremote) {
    if (-not $PythonLauncher) {
        throw "Python was not found. Install Python first, then rerun this script."
    }
    Write-Step "mpremote not found; installing with pip..."
    & $PythonLauncher[0] -m pip install --upgrade mpremote
    $MpremoteExe = Get-Command mpremote -ErrorAction SilentlyContinue
}

$UsePythonModule = $false
if (-not $MpremoteExe) {
    if ($PythonLauncher) {
        Write-Step "mpremote executable not found; trying python -m mpremote..."
        & $PythonLauncher[0] -m mpremote --help *> $null
        if ($LASTEXITCODE -eq 0) {
            $UsePythonModule = $true
        }
    }
}

if (-not $MpremoteExe -and -not $UsePythonModule) {
    throw "mpremote was not found. Install it with: py -m pip install mpremote   Then rerun, or rerun this script with -InstallMpremote."
}

function Invoke-Mpremote([string[]]$ArgsList) {
    if ($UsePythonModule) {
        & $PythonLauncher[0] -m mpremote @ArgsList
    } else {
        & $MpremoteExe.Source @ArgsList
    }
    if ($LASTEXITCODE -ne 0) {
        throw "mpremote failed: $($ArgsList -join ' ')"
    }
}

function Invoke-MpremoteNoThrow([string[]]$ArgsList) {
    try {
        Invoke-Mpremote $ArgsList
        return $true
    } catch {
        return $false
    }
}

function Ensure-RemoteDir([string]$RemoteDir, [string[]]$ConnectArgs) {
    if ([string]::IsNullOrWhiteSpace($RemoteDir)) { return }
    $parts = $RemoteDir -split '/' | Where-Object { $_ -and $_.Trim().Length -gt 0 }
    $cur = ""
    foreach ($p in $parts) {
        if ($cur.Length -gt 0) { $cur = "$cur/$p" } else { $cur = $p }
        [void](Invoke-MpremoteNoThrow ($ConnectArgs + @("fs", "mkdir", ":$cur")))
    }
}

function Get-RemoteRelPath([System.IO.FileInfo]$File, [string]$RootDir) {
    $rel = $File.FullName.Substring($RootDir.Length).TrimStart([char[]]@('\', '/'))
    return ($rel -replace '\\', '/')
}

$ResolvedZip = Resolve-Path $ZipPath -ErrorAction Stop
$WorkRoot = Join-Path $env:TEMP ("esp32s3_firmware_upload_" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $WorkRoot | Out-Null

try {
    Write-Step "Extracting $ResolvedZip"
    Expand-Archive -Path $ResolvedZip -DestinationPath $WorkRoot -Force
    $FirmwareDir = Join-Path $WorkRoot "esp32s3_firmware"
    if (-not (Test-Path $FirmwareDir)) {
        $candidate = Get-ChildItem -Path $WorkRoot -Directory | Select-Object -First 1
        if ($candidate) { $FirmwareDir = $candidate.FullName }
    }
    if (-not (Test-Path $FirmwareDir)) {
        throw "Could not find esp32s3_firmware directory inside ZIP."
    }

    $connectArgs = @("connect", $Port)

    if (-not $NoClean) {
        Write-Step "Removing old matching firmware files from board root"
        $deleteNames = @(
            "app_state.py", "battery_monitor.py", "battery_runtime.py", "board.py", "board_370.py",
            "boot.py", "brightness_modes.py", "buttons.py", "config.py", "demo_faces.py", "display_num.py",
            "emoji_db.py", "esp32s3_network.py", "esp32s3_wifi_ap.py", "esp32s3_wifi_boot.py", "main.py", "matrix_demos.py", "rina_protocol.py",
            "saved_faces_370.py", "settings_store.py", "webui_index.html.gz", "webui_runtime.py", "wifi_config.py",
            "EXTERNAL_CODE_COMMENTS.md", "upload_esp32s3_firmware.ps1", "__pycache__"
        )
        foreach ($name in $deleteNames) {
            [void](Invoke-MpremoteNoThrow ($connectArgs + @("fs", "rm", ":$name")))
        }
        # Remove previous lazy asset shards when the installed mpremote build supports recursive delete.
        [void](Invoke-MpremoteNoThrow ($connectArgs + @("fs", "rm", "-r", ":assets")))
        [void](Invoke-MpremoteNoThrow ($connectArgs + @("fs", "rmdir", ":assets")))
    }

    Write-Step "Uploading firmware files recursively"
    $files = Get-ChildItem -Path $FirmwareDir -File -Recurse | Where-Object {
        $_.Name -notlike "*.ps1" -and $_.Name -ne "EXTERNAL_CODE_COMMENTS.md"
    } | Sort-Object FullName

    foreach ($file in $files) {
        $remoteRel = Get-RemoteRelPath -File $file -RootDir $FirmwareDir
        $slash = $remoteRel.LastIndexOf('/')
        if ($slash -ge 0) {
            Ensure-RemoteDir -RemoteDir $remoteRel.Substring(0, $slash) -ConnectArgs $connectArgs
        }
        Write-Step "Uploading $remoteRel"
        Invoke-Mpremote ($connectArgs + @("fs", "cp", $file.FullName, ":$remoteRel"))
    }

    Write-Step "Resetting ESP32-S3"
    Invoke-Mpremote ($connectArgs + @("reset"))
    Write-Step "Done. Reopen Thonny/serial console after the board reboots."
}
finally {
    Remove-Item -Path $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}
