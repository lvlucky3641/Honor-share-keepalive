param(
    [Parameter(Position = 0)]
    [ValidateSet('Menu', 'Install', 'Start', 'Stop', 'Check', 'Status', 'Uninstall', 'Watchdog')]
    [string]$Command = 'Menu'
)

$ErrorActionPreference = 'Stop'
try {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [Console]::InputEncoding = $utf8
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
}
catch {
    # Console encoding is best-effort; command execution continues.
}

$TaskName = 'HONOR Share Keep Alive'
$WatchdogTaskName = 'HONOR Share Keep Alive Watchdog'
$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Launcher = Join-Path $RootDir 'launch-hidden.vbs'
$RuntimeDir = Join-Path $RootDir '.runtime'
$StopFlag = Join-Path $RuntimeDir 'stop.request'
$PidFile = Join-Path $RuntimeDir 'keepalive.pid'
$HealthFile = Join-Path $RuntimeDir 'health.json'
$LogFile = Join-Path $RootDir 'logs\keepalive.log'
$WatchdogLogFile = Join-Path $RootDir 'logs\watchdog.log'
$WScript = Join-Path $env:SystemRoot 'System32\wscript.exe'
$WatchdogModule = Join-Path $RootDir 'scripts\watchdog.ps1'
$WatchdogLauncher = Join-Path $RootDir 'watchdog-hidden.vbs'

foreach ($requiredFile in @($WatchdogModule, $WatchdogLauncher)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Watchdog file not found: $requiredFile"
    }
}

. $WatchdogModule

function Get-KeepAliveTask {
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

function Get-CurrentKeepAliveTask {
    $task = Get-KeepAliveTask
    if (
        Test-KeepAliveTaskCommand `
            -Task $task `
            -ExpectedExecutable $WScript `
            -ExpectedLauncher $Launcher
    ) {
        return $task
    }

    return $null
}

function Get-KeepAliveWatchdogTask {
    Get-ScheduledTask -TaskName $WatchdogTaskName -ErrorAction SilentlyContinue
}

function Get-WorkerProcesses {
    param(
        [switch]$AllCopies
    )

    $workerScript = Join-Path $RootDir 'keepalive.js'
    $needle = if ($AllCopies) { 'keepalive.js' } else { $workerScript }

    Get-CimInstance Win32_Process -Filter "Name='Hihonornote.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($needle) }
}

function Get-HealthSnapshot {
    if (-not (Test-Path -LiteralPath $HealthFile)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $HealthFile -Raw -Encoding utf8 | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Stop-Worker {
    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
    Set-Content -LiteralPath $StopFlag -Value 'stop' -Encoding utf8

    $task = Get-KeepAliveTask
    if ($task -and $task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $TaskName
    }

    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-WorkerProcesses -AllCopies).Count -eq 0) {
            break
        }
        Start-Sleep -Milliseconds 250
    }

    foreach ($worker in @(Get-WorkerProcesses -AllCopies)) {
        Stop-Process -Id $worker.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Register-KeepAliveTask {
    $existingTask = Get-KeepAliveTask
    if ($existingTask) {
        if ($existingTask.State -eq 'Running') {
            Stop-ScheduledTask -TaskName $TaskName
        }
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    $userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $taskAction = New-ScheduledTaskAction `
        -Execute $WScript `
        -Argument "//B //NoLogo `"$Launcher`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
    $principal = New-ScheduledTaskPrincipal `
        -UserId $userId `
        -LogonType Interactive `
        -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 3 `
        -RestartInterval ([TimeSpan]::FromMinutes(1)) `
        -MultipleInstances IgnoreNew

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $taskAction `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'Keeps HONOR Share discoverable without showing a desktop window.' | Out-Null
}

function Write-WatchdogLog {
    param(
        [string]$Message
    )

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $WatchdogLogFile) |
        Out-Null
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [WATCHDOG] $Message`r`n"
    [System.IO.File]::AppendAllText(
        $WatchdogLogFile,
        $line,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Stop-KeepAliveWatchdogTask {
    $task = Get-KeepAliveWatchdogTask
    if ($task) {
        if ($task.State -eq 'Running') {
            Stop-ScheduledTask -TaskName $WatchdogTaskName
        }
        if ($task.State -ne 'Disabled') {
            Disable-ScheduledTask -TaskName $WatchdogTaskName | Out-Null
        }
    }
}

function Register-KeepAliveWatchdogTask {
    $existingTask = Get-KeepAliveWatchdogTask
    if ($existingTask) {
        if ($existingTask.State -eq 'Running') {
            Stop-ScheduledTask -TaskName $WatchdogTaskName
        }
        Unregister-ScheduledTask -TaskName $WatchdogTaskName -Confirm:$false
    }

    $userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $actionSpec = Get-KeepAliveWatchdogTaskAction `
        -WScript $WScript `
        -Launcher $WatchdogLauncher
    $taskAction = New-ScheduledTaskAction `
        -Execute $actionSpec.Execute `
        -Argument $actionSpec.Arguments
    $repeatTrigger = New-ScheduledTaskTrigger `
        -Once `
        -At ((Get-Date).AddMinutes(1)) `
        -RepetitionInterval ([TimeSpan]::FromMinutes(1)) `
        -RepetitionDuration ([TimeSpan]::FromDays(3650))
    $principal = New-ScheduledTaskPrincipal `
        -UserId $userId `
        -LogonType Interactive `
        -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::FromMinutes(5)) `
        -MultipleInstances IgnoreNew

    Register-ScheduledTask `
        -TaskName $WatchdogTaskName `
        -Action $taskAction `
        -Trigger $repeatTrigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'Restarts the HONOR Share keepalive worker after updates or unexpected exits.' |
        Out-Null
}

function Invoke-KeepAliveWatchdogNow {
    return Invoke-KeepAliveWatchdog `
        -GetTask { Get-CurrentKeepAliveTask } `
        -GetWorkers { Get-WorkerProcesses -AllCopies } `
        -ExpectedWorkerScript (Join-Path $RootDir 'keepalive.js') `
        -RegisterTask { Register-KeepAliveTask } `
        -StartTask { Start-ScheduledTask -TaskName $TaskName } `
        -StopTask { Stop-ScheduledTask -TaskName $TaskName } `
        -StopAllWorkers { Stop-Worker } `
        -Log { param($message) Write-WatchdogLog $message }
}

function Get-SelfCheckResult {
    $task = Get-KeepAliveTask
    $watchdogTask = Get-KeepAliveWatchdogTask
    $workers = @(Get-WorkerProcesses)
    $health = Get-HealthSnapshot
    $issues = [System.Collections.Generic.List[string]]::new()

    if (-not $task) {
        $issues.Add('Scheduled task is not installed.')
    }
    elseif (-not (Test-KeepAliveTaskCommand -Task $task -ExpectedExecutable $WScript -ExpectedLauncher $Launcher)) {
        $issues.Add('Scheduled task points to a different keepalive installation.')
    }
    elseif ($task.State -ne 'Running') {
        $issues.Add("Scheduled task state is $($task.State), not Running.")
    }

    if (-not $watchdogTask) {
        $issues.Add('Watchdog scheduled task is not installed.')
    }
    elseif ($watchdogTask.State -eq 'Disabled') {
        $issues.Add('Watchdog scheduled task is disabled.')
    }

    if ($workers.Count -ne 1) {
        $issues.Add("Worker count is $($workers.Count); expected exactly 1.")
    }

    if (-not $health) {
        $issues.Add('Health heartbeat file has not been created.')
    }
    else {
        if ($workers.Count -eq 1 -and $health.pid -ne $workers[0].ProcessId) {
            $issues.Add('Health heartbeat PID does not match the running worker.')
        }
        if ($health.listenerStatus -ne 1) {
            $issues.Add('The latest check did not confirm discoverability is ON.')
        }

        try {
            $updatedAt = [DateTimeOffset]::Parse($health.updatedAt)
            $ageSeconds = ([DateTimeOffset]::UtcNow - $updatedAt.ToUniversalTime()).TotalSeconds
            if ($ageSeconds -gt 90) {
                $issues.Add("Health heartbeat is stale by $([math]::Round($ageSeconds)) seconds.")
            }
        }
        catch {
            $issues.Add('Health heartbeat timestamp is invalid.')
        }
    }

    return [pscustomobject]@{
        Ok = $issues.Count -eq 0
        Issues = $issues
        Task = $task
        WatchdogTask = $watchdogTask
        Workers = $workers
        Health = $health
    }
}

function Write-SelfCheck {
    $result = Get-SelfCheckResult
    $script:SelfCheckPassed = $result.Ok

    Write-Host ''
    Write-Host '=== Honor Share Keep Alive Self Check ==='
    Write-Host "Scheduled task : $(if ($result.Task) { $result.Task.State } else { 'Not installed' })"
    Write-Host "Watchdog task  : $(if ($result.WatchdogTask) { $result.WatchdogTask.State } else { 'Not installed' })"
    Write-Host "Worker count   : $($result.Workers.Count)"
    if ($result.Health) {
        Write-Host "Discoverable   : $(if ($result.Health.listenerStatus -eq 1) { 'ON' } else { 'NOT CONFIRMED' })"
        Write-Host "Last heartbeat : $($result.Health.updatedAt)"
    }
    else {
        Write-Host 'Discoverable   : NOT CONFIRMED'
        Write-Host 'Last heartbeat : none'
    }
    Write-Host ''

    if ($result.Ok) {
        Write-Host 'SELF-CHECK: PASS - background service is running and HONOR Share is discoverable.' -ForegroundColor Green
        return $true
    }

    Write-Host 'SELF-CHECK: FAILED' -ForegroundColor Red
    foreach ($issue in $result.Issues) {
        Write-Host "  - $issue" -ForegroundColor Yellow
    }

    if (Test-Path -LiteralPath $LogFile) {
        Write-Host ''
        Write-Host 'Latest log lines:'
        Get-Content -LiteralPath $LogFile -Encoding utf8 -Tail 8
    }

    return $false
}

function Wait-ForHealthyWorker {
    param(
        [int]$TimeoutSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $result = Get-SelfCheckResult
        if ($result.Ok) {
            return $result
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return $result
}

function Write-Status {
    $task = Get-KeepAliveTask
    $watchdogTask = Get-KeepAliveWatchdogTask
    $workers = @(Get-WorkerProcesses)
    $health = Get-HealthSnapshot

    Write-Host "计划任务    : $(if ($task) { "$($task.TaskName) [$($task.State)]" } else { '未安装' })"
    Write-Host "自动恢复    : $(if ($watchdogTask) { "$($watchdogTask.TaskName) [$($watchdogTask.State)]" } else { '未安装' })"
    Write-Host "后台实例    : $(if ($workers.Count) { $workers.ProcessId -join ', ' } else { '无' })"
    Write-Host "荣耀分享    : $(if ($health) { if ($health.listenerStatus -eq 1) { '已开启' } else { '未确认开启' } } else { '未知' })"
    if ($health) {
        Write-Host "最近心跳    : $($health.updatedAt)"
    }
}

function Start-KeepAlive {
    Stop-Worker
    Remove-Item -LiteralPath $StopFlag -Force -ErrorAction SilentlyContinue
    Register-KeepAliveTask
    Register-KeepAliveWatchdogTask
    Start-ScheduledTask -TaskName $TaskName
    Wait-ForHealthyWorker | Out-Null
    return (Write-SelfCheck)
}

function Stop-KeepAlive {
    Stop-KeepAliveWatchdogTask
    Stop-Worker
    Remove-Item -LiteralPath $HealthFile -Force -ErrorAction SilentlyContinue

    $task = Get-KeepAliveTask
    $watchdogTask = Get-KeepAliveWatchdogTask
    $workers = @(Get-WorkerProcesses)
    return (
        $workers.Count -eq 0 -and
        (-not $task -or $task.State -ne 'Running') -and
        (-not $watchdogTask -or $watchdogTask.State -ne 'Running')
    )
}

function Uninstall-KeepAlive {
    Stop-KeepAliveWatchdogTask
    Stop-Worker
    if (Get-KeepAliveTask) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    if (Get-KeepAliveWatchdogTask) {
        Unregister-ScheduledTask -TaskName $WatchdogTaskName -Confirm:$false
    }
    Remove-Item -LiteralPath $StopFlag -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $HealthFile -Force -ErrorAction SilentlyContinue

    return (
        -not (Get-KeepAliveTask) -and
        -not (Get-KeepAliveWatchdogTask) -and
        @(Get-WorkerProcesses).Count -eq 0
    )
}

function Invoke-InteractiveMenu {
    while ($true) {
        Clear-Host
        Write-Host '================================================'
        Write-Host '          荣耀分享后台保活 - 控制面板'
        Write-Host '================================================'
        Write-Host ''
        Write-Host '当前状态'
        Write-Status
        Write-Host ''
        Write-Host '1. 启动/修复，并设置登录自动启动'
        Write-Host '2. 执行完整自检'
        Write-Host '3. 停止后台服务'
        Write-Host '4. 停止并删除登录自动启动'
        Write-Host ''

        $choice = (Read-Host '请输入 1、2、3 或 4').Trim()
        if ($choice -notin @('1', '2', '3', '4')) {
            Write-Host ''
            Write-Host '输入无效，请输入 1、2、3 或 4。' -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            continue
        }

        $success = $false
        $resultText = ''

        switch ($choice) {
            '1' {
                $success = Start-KeepAlive
                $resultText = '启动/修复'
            }
            '2' {
                $success = Write-SelfCheck
                $resultText = '自检'
            }
            '3' {
                $success = Stop-KeepAlive
                $resultText = '停止服务'
            }
            '4' {
                $success = Uninstall-KeepAlive
                $resultText = '卸载自启动'
            }
        }

        Write-Host ''
        if ($success) {
            Write-Host "操作成功：$resultText 已完成。" -ForegroundColor Green
        }
        else {
            Write-Host "操作失败：$resultText 未成功完成，请查看上方反馈。" -ForegroundColor Red
        }

        for ($remaining = 3; $remaining -ge 1; $remaining--) {
            Write-Host "窗口将在 $remaining 秒后自动关闭..."
            Start-Sleep -Seconds 1
        }

        $script:MenuActionSucceeded = $success
        return
    }
}

$script:SelfCheckPassed = $null
$script:MenuActionSucceeded = $null

switch ($Command) {
    'Menu' {
        Invoke-InteractiveMenu
    }

    'Install' {
        $script:SelfCheckPassed = Start-KeepAlive
    }

    'Start' {
        $script:SelfCheckPassed = Start-KeepAlive
    }

    'Stop' {
        if (Stop-KeepAlive) {
            Write-Host 'STOPPED: the background worker is not running.'
        }
        else {
            $script:SelfCheckPassed = $false
        }
    }

    'Check' {
        Write-SelfCheck | Out-Null
    }

    'Status' {
        Write-Status
    }

    'Uninstall' {
        if (Uninstall-KeepAlive) {
            Write-Host 'UNINSTALLED: the scheduled task was removed.'
        }
        else {
            $script:SelfCheckPassed = $false
        }
    }

    'Watchdog' {
        try {
            $watchdogResult = Invoke-KeepAliveWatchdogNow
            if ($watchdogResult.Action -eq 'DuplicateWorkers') {
                exit 1
            }
        }
        catch {
            Write-WatchdogLog "Watchdog failed: $($_.Exception.Message)"
            throw
        }
    }
}

if ($null -ne $script:SelfCheckPassed -and -not $script:SelfCheckPassed) {
    exit 1
}
if ($Command -eq 'Menu' -and $script:MenuActionSucceeded -eq $false) {
    exit 1
}
