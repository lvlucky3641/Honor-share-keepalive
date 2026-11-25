$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'watchdog.ps1')

function Assert-Equal {
    param(
        $Actual,
        $Expected,
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message. Expected '$Expected', got '$Actual'."
    }
}

function Assert-Sequence {
    param(
        [System.Collections.Generic.List[string]]$Calls,
        [string[]]$Expected
    )

    $actual = $Calls -join ','
    $expectedText = $Expected -join ','
    Assert-Equal $actual $expectedText 'Unexpected watchdog calls'
}

$currentWorkerScript = 'C:\apps\keepalive-v1.3.3\keepalive.js'
$expectedWScript = 'C:\Windows\System32\wscript.exe'
$currentLauncher = 'C:\apps\keepalive-v1.3.3\launch-hidden.vbs'
$oldLauncher = 'C:\apps\keepalive-v1.3.1\launch-hidden.vbs'

'task action validation accepts the current installation and rejects an older one'
$currentTask = [pscustomobject]@{
    Actions = @([pscustomobject]@{
        Execute = $expectedWScript
        Arguments = "//B //NoLogo `"$currentLauncher`""
    })
}
$oldTask = [pscustomobject]@{
    Actions = @([pscustomobject]@{
        Execute = $expectedWScript
        Arguments = "//B //NoLogo `"$oldLauncher`""
    })
}
Assert-Equal (Test-KeepAliveTaskCommand -Task $currentTask -ExpectedExecutable $expectedWScript -ExpectedLauncher $currentLauncher) $true 'Current task action should match'
Assert-Equal (Test-KeepAliveTaskCommand -Task $oldTask -ExpectedExecutable $expectedWScript -ExpectedLauncher $currentLauncher) $false 'Old task action should not match'

'watchdog task uses the hidden VBS launcher instead of starting PowerShell directly'
$watchdogAction = Get-KeepAliveWatchdogTaskAction `
    -WScript $expectedWScript `
    -Launcher 'C:\apps\keepalive-v1.3.5\watchdog-hidden.vbs'
Assert-Equal $watchdogAction.Execute $expectedWScript 'Watchdog must be launched through wscript'
Assert-Equal $watchdogAction.Arguments '//B //NoLogo "C:\apps\keepalive-v1.3.5\watchdog-hidden.vbs"' 'Watchdog VBS arguments should be hidden and non-interactive'

'ready task with no worker starts the main task'
$calls = [System.Collections.Generic.List[string]]::new()
$result = Invoke-KeepAliveWatchdog `
    -GetTask { [pscustomobject]@{ State = 'Ready' } } `
    -GetWorkers { @() } `
    -ExpectedWorkerScript $currentWorkerScript `
    -RegisterTask { $calls.Add('register') } `
    -StartTask { $calls.Add('start') } `
    -StopTask { $calls.Add('stop') } `
    -StopAllWorkers { $calls.Add('stop-all') } `
    -Wait { param($milliseconds) } `
    -Log { param($message) }
Assert-Equal $result.Action 'Started' 'Ready task should be started'
Assert-Sequence $calls @('start')

'running task with no worker is restarted'
$calls = [System.Collections.Generic.List[string]]::new()
$result = Invoke-KeepAliveWatchdog `
    -GetTask { [pscustomobject]@{ State = 'Running' } } `
    -GetWorkers { @() } `
    -ExpectedWorkerScript $currentWorkerScript `
    -RegisterTask { $calls.Add('register') } `
    -StartTask { $calls.Add('start') } `
    -StopTask { $calls.Add('stop') } `
    -StopAllWorkers { $calls.Add('stop-all') } `
    -Wait { param($milliseconds) } `
    -Log { param($message) }
Assert-Equal $result.Action 'Restarted' 'Stale running task should be restarted'
Assert-Sequence $calls @('stop', 'start')

'one worker is healthy and does not receive another start'
$calls = [System.Collections.Generic.List[string]]::new()
$result = Invoke-KeepAliveWatchdog `
    -GetTask { [pscustomobject]@{ State = 'Running' } } `
    -GetWorkers { @([pscustomobject]@{ ProcessId = 11; CommandLine = "`"Hihonornote.exe`" `"$currentWorkerScript`"" }) } `
    -ExpectedWorkerScript $currentWorkerScript `
    -RegisterTask { $calls.Add('register') } `
    -StartTask { $calls.Add('start') } `
    -StopTask { $calls.Add('stop') } `
    -StopAllWorkers { $calls.Add('stop-all') } `
    -Wait { param($milliseconds) } `
    -Log { param($message) }
Assert-Equal $result.Action 'Healthy' 'Single worker should be healthy'
Assert-Sequence $calls @()

'multiple workers are reported without destructive restart'
$calls = [System.Collections.Generic.List[string]]::new()
$result = Invoke-KeepAliveWatchdog `
    -GetTask { [pscustomobject]@{ State = 'Running' } } `
    -GetWorkers { @([pscustomobject]@{ ProcessId = 11; CommandLine = "`"Hihonornote.exe`" `"$currentWorkerScript`"" }, [pscustomobject]@{ ProcessId = 12; CommandLine = "`"Hihonornote.exe`" `"$currentWorkerScript`"" }) } `
    -ExpectedWorkerScript $currentWorkerScript `
    -RegisterTask { $calls.Add('register') } `
    -StartTask { $calls.Add('start') } `
    -StopTask { $calls.Add('stop') } `
    -StopAllWorkers { $calls.Add('stop-all') } `
    -Wait { param($milliseconds) } `
    -Log { param($message) }
Assert-Equal $result.Action 'DuplicateWorkers' 'Duplicate workers should be reported'
Assert-Sequence $calls @()

'missing main task is recreated and started'
$calls = [System.Collections.Generic.List[string]]::new()
$result = Invoke-KeepAliveWatchdog `
    -GetTask { $null } `
    -GetWorkers { @() } `
    -ExpectedWorkerScript $currentWorkerScript `
    -RegisterTask { $calls.Add('register') } `
    -StartTask { $calls.Add('start') } `
    -StopTask { $calls.Add('stop') } `
    -StopAllWorkers { $calls.Add('stop-all') } `
    -Wait { param($milliseconds) } `
    -Log { param($message) }
Assert-Equal $result.Action 'Recreated' 'Missing main task should be recreated'
Assert-Sequence $calls @('register', 'start')

'missing task with a live worker is recreated without starting a duplicate'
$calls = [System.Collections.Generic.List[string]]::new()
$result = Invoke-KeepAliveWatchdog `
    -GetTask { $null } `
    -GetWorkers { @([pscustomobject]@{ ProcessId = 11; CommandLine = "`"Hihonornote.exe`" `"$currentWorkerScript`"" }) } `
    -ExpectedWorkerScript $currentWorkerScript `
    -RegisterTask { $calls.Add('register') } `
    -StartTask { $calls.Add('start') } `
    -StopTask { $calls.Add('stop') } `
    -StopAllWorkers { $calls.Add('stop-all') } `
    -Wait { param($milliseconds) } `
    -Log { param($message) }
Assert-Equal $result.Action 'TaskRecreated' 'Live worker should keep the task registration without another start'
Assert-Sequence $calls @('register')

'a worker from an older installation is migrated once instead of being restarted every minute'
$calls = [System.Collections.Generic.List[string]]::new()
$result = Invoke-KeepAliveWatchdog `
    -GetTask { $null } `
    -GetWorkers { @([pscustomobject]@{ ProcessId = 11; CommandLine = '"Hihonornote.exe" "C:\apps\keepalive-v1.3.1\keepalive.js"' }) } `
    -ExpectedWorkerScript $currentWorkerScript `
    -RegisterTask { $calls.Add('register') } `
    -StartTask { $calls.Add('start') } `
    -StopTask { $calls.Add('stop') } `
    -StopAllWorkers { $calls.Add('stop-all') } `
    -Wait { param($milliseconds) } `
    -Log { param($message) }
Assert-Equal $result.Action 'Migrated' 'Old worker should be migrated to the current installation'
Assert-Equal $result.ForeignWorkerCount 1 'Migration should report the foreign worker'
Assert-Sequence $calls @('stop-all', 'register', 'start')

Write-Host 'WATCHDOG TESTS: PASS'
