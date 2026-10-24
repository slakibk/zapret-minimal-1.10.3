param([ValidateSet('Start','Reprobe','Stop')][string]$Action = 'Start')
$ErrorActionPreference = 'Stop'
$LogDir = Join-Path $PSScriptRoot 'logs'
$LogPath = Join-Path $LogDir 'zapret.log'
$ZapretStatePath = Join-Path $LogDir 'zapret-strategy.txt'
$FixedZapret = $false
$ForceZapretProbe = $Action -eq 'Reprobe'
$Config = [ordered]@{
    ZapretBatPath = (Join-Path $PSScriptRoot 'zapret-discord-youtube-1.10.3\general (ALT).bat')
    ZapretHealthChecks = @(
        [PSCustomObject]@{
            Name = 'YouTube'
            RequiredUrls = @(
                'https://www.youtube.com/generate_204',
                'https://www.youtube.com/favicon.ico'
            )
        },
        [PSCustomObject]@{
            Name = 'Discord'
            RequiredUrls = @(
                'https://discord.com/api/v10/gateway',
                'https://updates.discord.com/distributions/app/manifests/latest?channel=stable&platform=win&arch=x64'
            )
            OptionalUrls = @(
                'https://gateway.discord.gg/'
            )
        }
    )
}

function Write-Step {
    param([string]$Message)
    Write-Host "[*] $Message"
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[!!] $Message" -ForegroundColor Yellow
}

function Stop-DiscordIfRunning {
    $processes = Get-Process -Name 'Discord' -ErrorAction SilentlyContinue
    if (-not $processes) {
        return
    }

    Write-Step 'Closing Discord before switching zapret profile'
    foreach ($process in $processes) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
        } catch {
            Write-Warn "Could not stop Discord PID $($process.Id): $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds 2
}

function Start-Zapret {
    param([string]$BatPath = $Config.ZapretBatPath)

    if (-not (Test-Path -LiteralPath $BatPath)) {
        Write-Warn "zapret batch not found: $BatPath"
        return $false
    }

    if (Get-Process -Name 'winws' -ErrorAction SilentlyContinue) {
        Write-Ok "zapret winws is already running"
        return $true
    }

    Write-Step "Starting zapret profile: $([IO.Path]::GetFileName($BatPath))"
    $previousNoUpdateCheck = $env:NO_UPDATE_CHECK
    try {
        $env:NO_UPDATE_CHECK = '1'
        Start-Process -FilePath $BatPath -WorkingDirectory ([IO.Path]::GetDirectoryName($BatPath)) -WindowStyle Minimized | Out-Null
    } finally {
        if ($null -eq $previousNoUpdateCheck) {
            Remove-Item Env:\NO_UPDATE_CHECK -ErrorAction SilentlyContinue
        } else {
            $env:NO_UPDATE_CHECK = $previousNoUpdateCheck
        }
    }
    Start-Sleep -Seconds 2
    return [bool](Get-Process -Name 'winws' -ErrorAction SilentlyContinue)
}

function Stop-Zapret {
    $processes = Get-Process -Name 'winws' -ErrorAction SilentlyContinue
    if (-not $processes) {
        return $true
    }

    Write-Step 'Stopping current zapret winws'
    $stoppedAll = $true
    foreach ($process in $processes) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
        } catch {
            $stoppedAll = $false
            Write-Warn "Could not stop winws PID $($process.Id): $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds 2
    if (Get-Process -Name 'winws' -ErrorAction SilentlyContinue) {
        $stoppedAll = $false
    }

    return $stoppedAll
}

function Test-WebUrl {
    param(
        [string]$Url,
        [int]$TimeoutSec = 8
    )

    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -Method Get -TimeoutSec $TimeoutSec
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500)
    } catch [System.Net.WebException] {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            return ($statusCode -ge 200 -and $statusCode -lt 500)
        }

        return $false
    } catch {
        return $false
    }
}

function Test-ZapretHealth {
    $failedGroups = 0

    foreach ($group in $Config.ZapretHealthChecks) {
        $groupOk = $false
        $requiredOk = 0

        foreach ($url in $group.RequiredUrls) {
            if (Test-WebUrl -Url $url) {
                Write-Ok "Health check passed [$($group.Name)]: $url"
                $requiredOk++
            } else {
                Write-Warn "Health check failed [$($group.Name)]: $url"
            }
        }

        $requiredCount = @($group.RequiredUrls).Count
        $groupOk = ($requiredOk -eq $requiredCount)

        if ($groupOk -and $group.OptionalUrls) {
            foreach ($url in $group.OptionalUrls) {
                if (Test-WebUrl -Url $url) {
                    Write-Ok "Optional health check passed [$($group.Name)]: $url"
                } else {
                    Write-Warn "Optional health check failed [$($group.Name)]: $url"
                }
            }
        }

        if (-not $groupOk) {
            $failedGroups++
            Write-Warn "Health group failed: $($group.Name)"
        }
    }

    return ($failedGroups -eq 0)
}

function Get-ZapretCandidatePaths {
    $zapretDir = [IO.Path]::GetDirectoryName($Config.ZapretBatPath)
    $paths = New-Object System.Collections.Generic.List[string]
    $allowed = @(Get-ChildItem -LiteralPath $zapretDir -Filter 'general*.bat' -File |
        Where-Object { $_.Name -match '^general \(ALT(?:[2-9]|1[0-3])?\)\.bat$' } |
        Sort-Object { if ($_.BaseName -eq 'general (ALT)') { 1 } else { [int]($_.BaseName -replace '\D', '') } })
    if (Test-Path -LiteralPath $ZapretStatePath) {
        $savedPath = Get-Content -LiteralPath $ZapretStatePath | Select-Object -First 1
        if ($savedPath -and $savedPath -in $allowed.FullName) { $paths.Add($savedPath) }
    }
    foreach ($candidate in $allowed) { $paths.Add($candidate.FullName) }

    $paths | Select-Object -Unique
}

function Start-ZapretAuto {
    if ($FixedZapret) {
        Start-Zapret
        return
    }

    if (Get-Process -Name 'winws' -ErrorAction SilentlyContinue) {
        Write-Step 'Restarting zapret to enforce ALT-only selection'
        Stop-DiscordIfRunning
        if (-not (Stop-Zapret)) {
            throw 'Cannot switch zapret profile because winws is still running.'
        }
    }

    $candidates = @(Get-ZapretCandidatePaths)
    if (-not $candidates) {
        throw "No zapret candidates found near: $($Config.ZapretBatPath)"
    }

    foreach ($candidate in $candidates) {
        if (-not (Stop-Zapret)) {
            throw 'Cannot switch zapret profile because winws is still running.'
        }

        if (-not (Start-Zapret -BatPath $candidate)) {
            Write-Warn "zapret did not start for: $([IO.Path]::GetFileName($candidate))"
            continue
        }

        if (-not (Get-Process -Name 'winws' -ErrorAction SilentlyContinue)) {
            Write-Warn "zapret did not start for: $([IO.Path]::GetFileName($candidate))"
            continue
        }

        if (Test-ZapretHealth) {
            Set-Content -LiteralPath $ZapretStatePath -Value $candidate -Encoding UTF8
            Write-Ok "Selected zapret profile: $([IO.Path]::GetFileName($candidate))"
            return
        }

        Write-Warn "Profile failed checks: $([IO.Path]::GetFileName($candidate))"
    }

    [void](Stop-Zapret)
    Remove-Item -LiteralPath $ZapretStatePath -ErrorAction SilentlyContinue
    throw 'No zapret profile passed HTTP checks. Stopped the failed profile; run service.bat diagnostics.'
}

$mutex = New-Object System.Threading.Mutex($false, 'Global\InternetOnZapretOnlyWorker')
$locked = $false
$logging = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another zapret operation is running.' }
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    Start-Transcript -Path $LogPath -Force | Out-Null
    $logging = $true
    if ($Action -eq 'Stop') {
        if (-not (Stop-Zapret)) { throw 'Could not stop zapret.' }
        Write-Ok 'Zapret stopped'
    } else { Start-ZapretAuto }
} catch {
    Write-Warn $_.Exception.Message
    exit 1
} finally {
    if ($logging) { Stop-Transcript | Out-Null }
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
