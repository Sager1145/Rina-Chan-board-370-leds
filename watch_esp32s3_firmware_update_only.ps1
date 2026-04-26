param(
    [string]$ZipPath = ".\esp32s3_firmware.zip",
    [int]$PollSeconds = 1,
    [switch]$UseHash
)

$ErrorActionPreference = "Stop"

$FolderName = "esp32s3_firmware"

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts] [$Level] $Message"
}

function Resolve-FullPathSafe {
    param([string]$PathText)

    if ([System.IO.Path]::IsPathRooted($PathText)) {
        return [System.IO.Path]::GetFullPath($PathText)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $PathText))
}

function Wait-ZipStable {
    param(
        [string]$Path,
        [int]$TimeoutSeconds = 120,
        [int]$IntervalMs = 500,
        [int]$StableChecksRequired = 4
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastLen = -1
    $lastWriteTicks = -1
    $stableCount = 0

    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path -LiteralPath $Path)) {
            Start-Sleep -Milliseconds $IntervalMs
            continue
        }

        try {
            $info = Get-Item -LiteralPath $Path -ErrorAction Stop

            $stream = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite
            )
            $stream.Close()

            $len = [int64]$info.Length
            $ticks = [int64]$info.LastWriteTimeUtc.Ticks

            if (($len -eq $lastLen) -and ($ticks -eq $lastWriteTicks) -and ($len -gt 0)) {
                $stableCount++
            } else {
                $stableCount = 0
                $lastLen = $len
                $lastWriteTicks = $ticks
            }

            if ($stableCount -ge $StableChecksRequired) {
                return $true
            }
        } catch {
            $stableCount = 0
        }

        Start-Sleep -Milliseconds $IntervalMs
    }

    return $false
}

function Get-ZipSignature {
    param(
        [string]$Path,
        [bool]$Hash
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $info = Get-Item -LiteralPath $Path -ErrorAction Stop

    if ($Hash) {
        try {
            $sha = Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop
            return "{0}|{1}|{2}" -f $info.Length, $info.LastWriteTimeUtc.Ticks, $sha.Hash
        } catch {
            Write-Log "Could not hash ZIP yet: $($_.Exception.Message)" "WARN"
            return "{0}|{1}|HASH_PENDING" -f $info.Length, $info.LastWriteTimeUtc.Ticks
        }
    }

    return "{0}|{1}" -f $info.Length, $info.LastWriteTimeUtc.Ticks
}

function Extract-OnlyFirmwareFolder {
    param(
        [string]$Zip,
        [string]$DestFolder
    )

    Write-Log "Update detected. Starting unzip: $Zip"

    if (-not (Test-Path -LiteralPath $Zip)) {
        Write-Log "ZIP not found. Waiting." "WARN"
        return $false
    }

    Write-Log "Waiting for ZIP to finish writing..."
    $stable = Wait-ZipStable -Path $Zip
    if (-not $stable) {
        Write-Log "ZIP did not become stable. Skipping this update." "ERROR"
        return $false
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("esp32s3_zip_extract_" + [guid]::NewGuid().ToString("N"))
    $tempExtract = Join-Path $tempRoot "extract"
    $tempFirmware = Join-Path $tempExtract $script:FolderName

    try {
        New-Item -ItemType Directory -Path $tempExtract -Force | Out-Null

        Write-Log "Extracting ZIP to temporary folder..."
        Expand-Archive -LiteralPath $Zip -DestinationPath $tempExtract -Force

        if (-not (Test-Path -LiteralPath $tempFirmware)) {
            Write-Log "ZIP does not contain a top-level '$script:FolderName' folder. Nothing copied." "ERROR"
            Write-Log "Expected inside ZIP: $script:FolderName\main.py, $script:FolderName\webui\, etc." "ERROR"
            return $false
        }

        if (-not (Test-Path -LiteralPath $DestFolder)) {
            New-Item -ItemType Directory -Path $DestFolder -Force | Out-Null
            Write-Log "Created destination folder: $DestFolder"
        }

        Write-Log "Overwriting only '$script:FolderName' beside the ZIP..."
        robocopy $tempFirmware $DestFolder /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
        $code = $LASTEXITCODE

        # Robocopy exit codes 0-7 are success or non-fatal warnings.
        if ($code -ge 8) {
            throw "robocopy failed with exit code $code"
        }

        Write-Log "Done. Destination folder overwritten: $DestFolder"
        return $true
    } catch {
        Write-Log "Extract/overwrite failed: $($_.Exception.Message)" "ERROR"
        return $false
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    $ZipPath = Resolve-FullPathSafe $ZipPath
    $ZipDir = Split-Path -Parent $ZipPath
    $Destination = Join-Path $ZipDir $FolderName

    Write-Log "ESP32-S3 firmware ZIP polling watcher started."
    Write-Log "Watching ZIP: $ZipPath"
    Write-Log "Destination fixed to: $Destination"
    Write-Log "Only copied from ZIP: $FolderName"
    Write-Log "Poll interval: $PollSeconds second(s)"
    Write-Log "UseHash: $([bool]$UseHash)"
    Write-Log "Startup behavior: NO unzip. The script only saves the current ZIP state."

    $lastSignature = $null

    if (Test-Path -LiteralPath $ZipPath) {
        $lastSignature = Get-ZipSignature -Path $ZipPath -Hash ([bool]$UseHash)
        Write-Log "Current ZIP signature saved. Waiting for the next update."
        Write-Log "Signature: $lastSignature"
    } else {
        Write-Log "ZIP does not exist yet. First appearance will be treated as an update." "WARN"
    }

    Write-Log "Watching for updates. Press Ctrl+C to stop."

    while ($true) {
        Start-Sleep -Seconds $PollSeconds

        if (-not (Test-Path -LiteralPath $ZipPath)) {
            continue
        }

        $currentSignature = Get-ZipSignature -Path $ZipPath -Hash ([bool]$UseHash)

        if ($null -eq $lastSignature) {
            Write-Log "ZIP appeared. Treating this as an update."
            $ok = Extract-OnlyFirmwareFolder -Zip $ZipPath -DestFolder $Destination
            if ($ok) {
                $lastSignature = Get-ZipSignature -Path $ZipPath -Hash ([bool]$UseHash)
                Write-Log "New signature saved: $lastSignature"
            }
            continue
        }

        if ($currentSignature -ne $lastSignature) {
            Write-Log "ZIP update detected."
            Write-Log "Old: $lastSignature"
            Write-Log "New: $currentSignature"

            $ok = Extract-OnlyFirmwareFolder -Zip $ZipPath -DestFolder $Destination
            if ($ok) {
                $lastSignature = Get-ZipSignature -Path $ZipPath -Hash ([bool]$UseHash)
                Write-Log "Updated signature saved: $lastSignature"
            } else {
                Write-Log "Update was not applied. Signature not advanced, so the script will retry." "WARN"
            }
        }
    }
} catch {
    Write-Log "Fatal error: $($_.Exception.Message)" "ERROR"
    exit 1
}
