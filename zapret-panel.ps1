param([switch]$CheckUI)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
if (-not $CheckUI) {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        [System.Windows.Forms.MessageBox]::Show('Закройте окно и откройте zapret.cmd через «Запуск от имени администратора».', 'Zapret — нужны права администратора') | Out-Null
        exit 1
    }
}
$zapretDir = Join-Path $PSScriptRoot 'zapret-discord-youtube-1.10.3'
$exePath = Join-Path $zapretDir 'bin\winws.exe'
$statePath = Join-Path $PSScriptRoot 'logs\zapret-strategy.txt'
$logPath = Join-Path $PSScriptRoot 'logs\zapret.log'
$enginePath = Join-Path $PSScriptRoot 'zapret-engine.ps1'
$profiles = @(Get-ChildItem -LiteralPath $zapretDir -Filter 'general*.bat' -File | Where-Object { $_.Name -match '^general \(ALT(?:[2-9]|1[0-3])?\)\.bat$' } | Sort-Object Name)
if (-not $profiles -or -not (Test-Path -LiteralPath $exePath)) { throw 'Не найдены файлы zapret.' }
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Zapret — управление'
$form.ClientSize = New-Object System.Drawing.Size(650, 500)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$title = New-Object System.Windows.Forms.Label
$title.Text = 'Zapret 1.10.3'
$title.SetBounds(20, 15, 600, 25)
$form.Controls.Add($title)
$status = New-Object System.Windows.Forms.Label
$status.SetBounds(20, 48, 610, 25)
$form.Controls.Add($status)
$label = New-Object System.Windows.Forms.Label
$label.Text = 'Профиль:'
$label.SetBounds(20, 85, 100, 25)
$form.Controls.Add($label)
$choice = New-Object System.Windows.Forms.Label
$choice.SetBounds(120, 85, 510, 30)
$choice.Text = 'Автоматический подбор ALT'
$form.Controls.Add($choice)
$start = New-Object System.Windows.Forms.Button
$start.Text = 'Запустить'
$start.SetBounds(20, 130, 180, 38)
$form.Controls.Add($start)
$restart = New-Object System.Windows.Forms.Button
$restart.Text = 'Подобрать заново'
$restart.SetBounds(215, 130, 220, 38)
$form.Controls.Add($restart)
$stop = New-Object System.Windows.Forms.Button
$stop.Text = 'Остановить'
$stop.SetBounds(450, 130, 180, 38)
$form.Controls.Add($stop)
$note = New-Object System.Windows.Forms.TextBox
$note.Multiline = $true
$note.ReadOnly = $true
$note.ScrollBars = 'Vertical'
$note.Text = 'Нажмите «Запустить»: профиль ALT будет выбран автоматически по проверкам YouTube и Discord. При смене стратегии Discord может быть закрыт, как в основной программе.'
$note.SetBounds(20, 185, 610, 295)
$form.Controls.Add($note)
$script:worker = $null
$script:showLog = $false
$script:resultText = ''
function Update-Status {
    if ($script:worker -and $script:worker.HasExited) {
        $script:worker.Refresh()
        $script:resultText = if ($script:worker.ExitCode -eq 0) { 'Операция завершена.' } else { 'Операция не выполнена. Подробности в журнале.' }
        $script:worker.Dispose()
        $script:worker = $null
    }
    $busy = $null -ne $script:worker
    $running = @(Get-Process -Name winws -ErrorAction SilentlyContinue).Count -gt 0
    $status.Text = if ($busy) { 'Идёт проверка / подбор стратегии…' } elseif ($running) { 'Zapret работает. ' + $script:resultText } else { 'Zapret остановлен. ' + $script:resultText }
    $start.Enabled = -not $busy
    $restart.Enabled = -not $busy
    $stop.Enabled = -not $busy -and $running
    if (Test-Path -LiteralPath $statePath) {
        $saved = Get-Content -LiteralPath $statePath | Select-Object -First 1
        $savedName = [IO.Path]::GetFileName($saved)
        $choice.Text = if ($savedName -in $profiles.Name) { $savedName } else { 'Автоматический подбор ALT (старый выбор исключён)' }
    } else { $choice.Text = 'Автоматический подбор ALT' }
    if ($script:showLog -and (Test-Path -LiteralPath $logPath)) {
        $note.Text = (Get-Content -LiteralPath $logPath -Tail 70 -ErrorAction SilentlyContinue) -join "`r`n"
        $note.SelectionStart = $note.TextLength
        $note.ScrollToCaret()
    }
}
function Start-Operation {
    param([string]$Action)
    if ($script:worker) { return }
    try {
        $script:worker = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', ('"' + $enginePath + '"'), '-Action', $Action) -WindowStyle Minimized -PassThru
        $script:showLog = $true
        $script:resultText = ''
        Update-Status
    } catch { $note.Text = $_.Exception.Message }
}
$start.Add_Click({ Start-Operation 'Start' })
$restart.Add_Click({ Start-Operation 'Reprobe' })
$stop.Add_Click({ Start-Operation 'Stop' })
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({ try { Update-Status } catch { $note.Text = $_.Exception.Message } })
Update-Status
if ($CheckUI) {
    if (-not (Test-Path -LiteralPath $enginePath) -or $form.Controls.Count -ne 8) { throw 'UI validation failed' }
    Write-Output ('UI OK; automatic profiles: ' + $profiles.Count)
    $timer.Dispose(); $form.Dispose()
    exit 0
}
$form.Add_FormClosing({
    if ($script:worker -and -not $script:worker.HasExited) {
        $_.Cancel = $true
        [System.Windows.Forms.MessageBox]::Show('Дождитесь окончания подбора. Его ход показан в журнале.', 'Zapret') | Out-Null
    }
})
$timer.Start()
try { [void]$form.ShowDialog() } finally { $timer.Stop(); $timer.Dispose(); $form.Dispose() }
