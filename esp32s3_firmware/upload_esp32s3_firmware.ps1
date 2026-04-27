# Parameters control which firmware ZIP is uploaded and how the ESP32-S3 upload session behaves.
param(
    # ZipPath points to the packaged firmware archive that will be extracted before upload.
    [string]$ZipPath = ".\esp32s3_firmware_rnt_stream_loader_1_7_3.zip",
    # Port selects the serial port for mpremote; "auto" lets mpremote discover the board.
    [string]$Port = "auto",
    # InstallMpremote allows this script to install mpremote when it is missing.
    [switch]$InstallMpremote,
    # NoClean preserves existing files on the board instead of removing known firmware files first.
    [switch]$NoClean
)

# ErrorActionPreference forces cmdlet failures to stop the script instead of being ignored.
$ErrorActionPreference = "Stop"

# Write-Step prints a consistent progress prefix for every user-visible upload step.
function Write-Step($Text) {
    # Text is the human-readable status message for the current upload operation.
    Write-Host "[ESP32S3] $Text"
}

# Find-PythonLauncher locates an available Python command that can run mpremote as a module.
function Find-PythonLauncher {
    # py stores the Windows Python launcher command if it exists on PATH.
    $py = Get-Command py -ErrorAction SilentlyContinue
    # Prefer the Windows py launcher because it reliably chooses an installed Python runtime.
    if ($py) { return @($py.Source) }
    # python stores the generic Python command if the launcher is unavailable.
    $python = Get-Command python -ErrorAction SilentlyContinue
    # Use python when it is available and py was not found.
    if ($python) { return @($python.Source) }
    # python3 stores the Unix-style Python command if this shell exposes one.
    $python3 = Get-Command python3 -ErrorAction SilentlyContinue
    # Use python3 as the final launcher fallback.
    if ($python3) { return @($python3.Source) }
    # Return null when no Python launcher is available.
    return $null
}

# MpremoteExe stores a directly runnable mpremote executable when it exists on PATH.
$MpremoteExe = Get-Command mpremote -ErrorAction SilentlyContinue
# PythonLauncher stores the Python executable path used for module-based mpremote execution.
$PythonLauncher = Find-PythonLauncher

# Install mpremote only when it is missing and the caller explicitly opted in.
if (-not $MpremoteExe -and $InstallMpremote) {
    # Python is required to install mpremote through pip.
    if (-not $PythonLauncher) {
        throw "Python was not found. Install Python first, then rerun this script."
    }
    # Report that the script is about to install the uploader dependency.
    Write-Step "mpremote not found; installing with pip..."
    # Install or upgrade mpremote into the selected Python environment.
    & $PythonLauncher[0] -m pip install --upgrade mpremote
    # Refresh the executable lookup after installation.
    $MpremoteExe = Get-Command mpremote -ErrorAction SilentlyContinue
}

# UsePythonModule records whether mpremote will be invoked as python -m mpremote.
$UsePythonModule = $false
# If no standalone executable exists, try running mpremote through Python.
if (-not $MpremoteExe) {
    # Only try python -m mpremote when a Python launcher was found.
    if ($PythonLauncher) {
        # Report the fallback strategy before probing it.
        Write-Step "mpremote executable not found; trying python -m mpremote..."
        # Probe mpremote without printing help text to the console.
        & $PythonLauncher[0] -m mpremote --help *> $null
        # LASTEXITCODE indicates whether the module probe succeeded.
        if ($LASTEXITCODE -eq 0) {
            # Use module execution for all later mpremote calls.
            $UsePythonModule = $true
        }
    }
}

# Stop early when neither mpremote invocation path is available.
if (-not $MpremoteExe -and -not $UsePythonModule) {
    throw "mpremote was not found. Install it with: py -m pip install mpremote   Then rerun, or rerun this script with -InstallMpremote."
}

# Invoke-Mpremote runs mpremote with the selected executable/module strategy and throws on failure.
function Invoke-Mpremote([string[]]$ArgsList) {
    # ArgsList contains the exact mpremote arguments for this board operation.
    if ($UsePythonModule) {
        # Run mpremote as a Python module when no executable was found.
        & $PythonLauncher[0] -m mpremote @ArgsList
    } else {
        # Run the direct mpremote executable when it is available.
        & $MpremoteExe.Source @ArgsList
    }
    # LASTEXITCODE carries the external command status and must be checked manually.
    if ($LASTEXITCODE -ne 0) {
        throw "mpremote failed: $($ArgsList -join ' ')"
    }
}

# Invoke-MpremoteNoThrow runs mpremote and converts success/failure into a Boolean.
function Invoke-MpremoteNoThrow([string[]]$ArgsList) {
    # The try block captures optional cleanup operations that may fail harmlessly.
    try {
        # Reuse the strict mpremote wrapper for the actual command.
        Invoke-Mpremote $ArgsList
        # Return true when the command completed successfully.
        return $true
    } catch {
        # Return false when an optional operation fails.
        return $false
    }
}

# Ensure-RemoteDir creates every directory segment needed for a remote board path.
function Ensure-RemoteDir([string]$RemoteDir, [string[]]$ConnectArgs) {
    # RemoteDir is empty when the file belongs at the board root.
    if ([string]::IsNullOrWhiteSpace($RemoteDir)) { return }
    # parts contains each non-empty path segment in upload order.
    $parts = $RemoteDir -split '/' | Where-Object { $_ -and $_.Trim().Length -gt 0 }
    # cur accumulates the remote path as each directory level is created.
    $cur = ""
    # Create each directory level; existing directories are treated as harmless failures.
    foreach ($p in $parts) {
        # Append the next path segment with a forward slash for the ESP filesystem.
        if ($cur.Length -gt 0) { $cur = "$cur/$p" } else { $cur = $p }
        # mkdir may fail if the directory already exists, so the no-throw wrapper is used.
        [void](Invoke-MpremoteNoThrow ($ConnectArgs + @("fs", "mkdir", ":$cur")))
    }
}

# Get-RemoteRelPath converts a local extracted file path into a board-relative upload path.
function Get-RemoteRelPath([System.IO.FileInfo]$File, [string]$RootDir) {
    # rel strips the extracted firmware root from the local file path.
    $rel = $File.FullName.Substring($RootDir.Length).TrimStart([char[]]@('\', '/'))
    # Return a slash-normalized path because the ESP filesystem expects forward slashes.
    return ($rel -replace '\\', '/')
}

# ResolvedZip stores the absolute path to the firmware archive and validates that it exists.
$ResolvedZip = Resolve-Path $ZipPath -ErrorAction Stop
# WorkRoot is a unique temporary extraction directory for this upload attempt.
$WorkRoot = Join-Path $env:TEMP ("esp32s3_firmware_upload_" + [Guid]::NewGuid().ToString("N"))
# Create the temporary extraction directory before entering the cleanup-protected block.
New-Item -ItemType Directory -Path $WorkRoot | Out-Null

# The try/finally block guarantees temporary files are removed after upload or failure.
try {
    # Report and extract the selected firmware ZIP.
    Write-Step "Extracting $ResolvedZip"
    Expand-Archive -Path $ResolvedZip -DestinationPath $WorkRoot -Force
    # FirmwareDir is the expected extracted firmware directory.
    $FirmwareDir = Join-Path $WorkRoot "esp32s3_firmware"
    # Fall back to the first extracted directory if the archive root has a different name.
    if (-not (Test-Path $FirmwareDir)) {
        # candidate stores the first directory found inside the extraction root.
        $candidate = Get-ChildItem -Path $WorkRoot -Directory | Select-Object -First 1
        # Use the discovered directory when one exists.
        if ($candidate) { $FirmwareDir = $candidate.FullName }
    }
    # Abort when the archive did not contain a usable firmware directory.
    if (-not (Test-Path $FirmwareDir)) {
        throw "Could not find esp32s3_firmware directory inside ZIP."
    }

    # connectArgs contains the mpremote connection prefix reused by every board command.
    $connectArgs = @("connect", $Port)

    # Unless disabled, remove known old firmware files before uploading this package.
    if (-not $NoClean) {
        # Report cleanup so the user knows the board root is being refreshed.
        Write-Step "Removing old matching firmware files from board root"
        # deleteNames lists firmware files and legacy filenames that should be removed from the board.
        $deleteNames = @(
            "app_state.py", "battery_monitor.py", "battery_runtime.py", "board.py", "board_370.py",
            "boot.py", "brightness_modes.py", "buttons.py", "config.py", "demo_faces.py", "display_num.py",
            "emoji_db.py", "esp32s3_network.py", "esp32s3_wifi_ap.py", "esp32s3_wifi_boot.py", "main.py", "matrix_demos.py", "rina_protocol.py",
            "app_module_base.py", "battery_module.py", "color_module.py", "face_module.py", "gpio_module.py", "home_module.py", "scroll_module.py", "unity_module.py", "wifi_module.py",
            "saved_faces_370.py", "settings_store.py", "webui_index.html.gz", "webui_runtime.py", "wifi_config.py",
            "EXTERNAL_CODE_COMMENTS.md", "upload_esp32s3_firmware.ps1", "__pycache__"
        )
        # Remove each known root-level file if it exists; missing files are harmless.
        foreach ($name in $deleteNames) {
            # name is the remote file or directory entry being cleaned from the board root.
            [void](Invoke-MpremoteNoThrow ($connectArgs + @("fs", "rm", ":$name")))
        }
        # Remove previous lazy asset shards when the installed mpremote build supports recursive delete.
        [void](Invoke-MpremoteNoThrow ($connectArgs + @("fs", "rm", "-r", ":assets")))
        # Remove the assets directory itself for mpremote builds that need a separate rmdir.
        [void](Invoke-MpremoteNoThrow ($connectArgs + @("fs", "rmdir", ":assets")))
    }

    # Report upload start before walking the extracted package files.
    Write-Step "Uploading firmware files recursively"
    # files stores every uploadable extracted file except local-only helper/documentation files.
    $files = Get-ChildItem -Path $FirmwareDir -File -Recurse | Where-Object {
        # Exclude the uploader script and external notes from the device filesystem.
        $_.Name -notlike "*.ps1" -and $_.Name -ne "EXTERNAL_CODE_COMMENTS.md"
    } | Sort-Object FullName

    # Upload every selected file, creating its remote parent directory first when needed.
    foreach ($file in $files) {
        # remoteRel is the slash-normalized path that will be used on the ESP filesystem.
        $remoteRel = Get-RemoteRelPath -File $file -RootDir $FirmwareDir
        # slash stores the last directory separator position in the remote path.
        $slash = $remoteRel.LastIndexOf('/')
        # Create the remote parent directory when the file is not at the root.
        if ($slash -ge 0) {
            Ensure-RemoteDir -RemoteDir $remoteRel.Substring(0, $slash) -ConnectArgs $connectArgs
        }
        # Report the individual file being uploaded for progress visibility.
        Write-Step "Uploading $remoteRel"
        # Copy the local extracted file to its matching board path.
        Invoke-Mpremote ($connectArgs + @("fs", "cp", $file.FullName, ":$remoteRel"))
    }

    # Reset the board so the newly uploaded firmware starts cleanly.
    Write-Step "Resetting ESP32-S3"
    Invoke-Mpremote ($connectArgs + @("reset"))
    # Report successful completion and remind the user to reopen serial tooling.
    Write-Step "Done. Reopen Thonny/serial console after the board reboots."
}
# finally guarantees local temporary cleanup even when extraction or upload fails.
finally {
    # Always remove this script's temporary extraction directory.
    Remove-Item -Path $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}
