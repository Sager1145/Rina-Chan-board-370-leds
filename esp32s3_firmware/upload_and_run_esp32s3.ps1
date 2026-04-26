param(
    [string]$Port = "",
    [switch]$NoErase,
    [switch]$OpenAP
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

function Invoke-Mpremote {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    if (Get-Command mpremote -ErrorAction SilentlyContinue) {
        & mpremote @Args
    } else {
        & py -m mpremote @Args
    }
}

function Should-UploadFile {
    param([System.IO.FileInfo]$File)
    $rel = Resolve-Path -Relative $File.FullName
    $rel = $rel.TrimStart('.', '\', '/') -replace '\\','/'
    if ($rel -match '(^|/)__pycache__(/|$)') { return $false }
    if ($rel -match '(^|/)tools(/|$)') { return $false }
    if ($File.Extension -in @('.ps1', '.txt', '.md', '.pyc')) { return $false }
    if ($File.Name -like '*CHANGELOG*') { return $false }
    if ($File.Name -like 'README*') { return $false }

    $runtimePy = @(
        'boot.py', 'main.py', 'config.py', 'wifi_config.py', 'logger.py',
        'board.py', 'buttons.py', 'battery.py', 'default_faces.py',
        'display_num.py', 'display_text.py', 'face_codec.py', 'face_parts.py',
        'network_manager.py', 'protocol_server.py', 'saved_faces.py', 'settings_store.py'
    )
    if ($File.Extension -eq '.py') {
        return $runtimePy -contains $File.Name
    }
    return $File.Extension -in @('.json', '.html', '.gz')
}

$connectArgs = @()
if ($Port -ne "") {
    $connectArgs = @("connect", $Port)
}

if ($OpenAP) {
    Write-Host "Switching local wifi_config.py to open AP compatibility mode before upload..."
    $WifiCfg = Join-Path $ScriptDir "wifi_config.py"
    $wifiText = Get-Content $WifiCfg -Raw
    $wifiText = $wifiText -replace 'AP_SSID\s*=\s*"[^"]*"', 'AP_SSID = "RinaChanBoard-S3-OPEN"'
    $wifiText = $wifiText -replace 'AP_PASSWORD\s*=\s*"[^"]*"', 'AP_PASSWORD = ""'
    $wifiText = $wifiText -replace 'AP_AUTHMODE\s*=\s*\d+', 'AP_AUTHMODE = 0'
    $wifiText = $wifiText -replace 'AP_COMPAT_OPEN\s*=\s*(True|False)', 'AP_COMPAT_OPEN = True'
    Set-Content -Path $WifiCfg -Value $wifiText -NoNewline
}

if (-not $NoErase) {
    Write-Host "Deleting existing files on ESP32-S3..."
    $deleteCode = @'
import os

def rm_tree(path):
    try:
        entries = os.listdir(path)
    except Exception:
        entries = []
    for name in entries:
        if name in ('.', '..'):
            continue
        full = path.rstrip('/') + '/' + name if path != '/' else '/' + name
        try:
            st = os.stat(full)
            if st[0] & 0x4000:
                rm_tree(full)
                os.rmdir(full)
            else:
                os.remove(full)
        except Exception as e:
            print('skip/delete failed', full, e)

rm_tree('/')
print('erase complete')
'@
    Invoke-Mpremote @connectArgs exec $deleteCode
}

$files = Get-ChildItem -Path $ScriptDir -Recurse -File | Where-Object { Should-UploadFile $_ } | Sort-Object FullName

Write-Host "Creating runtime directories..."
$dirs = New-Object System.Collections.Generic.HashSet[string]
foreach ($file in $files) {
    $rel = Resolve-Path -Relative $file.DirectoryName
    $rel = $rel.TrimStart('.', '\', '/') -replace '\\','/'
    if ($rel -ne "") { [void]$dirs.Add($rel) }
}
foreach ($dir in ($dirs | Sort-Object)) {
    try { Invoke-Mpremote @connectArgs fs mkdir (":" + $dir) } catch { }
}

Write-Host "Uploading runtime files only..."
foreach ($file in $files) {
    $rel = Resolve-Path -Relative $file.FullName
    $rel = $rel.TrimStart('.', '\', '/') -replace '\\','/'
    Write-Host "  $rel"
    Invoke-Mpremote @connectArgs fs cp $file.FullName (":" + $rel)
}

Write-Host "Soft reset..."
Invoke-Mpremote @connectArgs reset
Write-Host "Done. Docs/comments were kept on the PC and were not uploaded to the ESP32-S3."
