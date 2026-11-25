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

'ready task with no worker starts the main task'
$calls = [System.Collections.Generic.List[string]]::new()
$result = Invoke-KeepAliveWatchdog `
    -GetTask { [pscustomobject]@{ State = 'Ready' } } `
    -GetWorkers { @() } `
    -RegisterTask { $calls.Add('register') } `
    -StartTask { $calls.Add('start') } `
    -StopTask { $calls.Add('stop') } `
    -Wait { param($milliseconds) } `
    -Log { param($message) }
Assert-Equal $result.Action 'Started' 'Ready task should be started'
Assert-Sequence $calls @('start')

'running task with no worker is restarted'
$calls = [System.Collections.Generic.List[string]]::new()
$result = Invoke-KeepAliveWatchdog `
    -GetTask { [pscustomobject]@{ State = 'Running' } } `
    -GetWorkers { @() } `
    -RegisterTask { $calls.Add('register') } `
    -StartTask { $calls.Add('start') } `
    -StopTask { $calls.Add('stop') } `
    -Wait { param($milliseconds) } `
    -Log { param($message) }
Assert-Equal $result.Action 'Restarted' 'Stale running task should be restarted'
Assert-Sequence $calls @('stop', 'start')

'one worker is healthy and does not receive another start'
$calls = [System.Collections.Generic.List[string]]::new()
$result = Invoke-KeepAliveWatchdog `
    -GetTask { [pscustomobject]@{ State = 'Running' } } `
    -GetWorkers { @([pscustomobject]@{ ProcessId = 11 }) } `
    -RegisterTask { $calls.Add('register') } `
    -StartTask { $calls.Add('start') } `
    -StopTask { $calls.Add('stop') } `
    -Wait { param($milliseconds) } `
    -Log { param($message) }
Assert-Equal $result.Action 'Healthy' 'Single worker should be healthy'
Assert-Sequence $calls @()

'multiple workers are reported without destructive restart'
$calls = [System.Collections.Generic.List[string]]::new()
$result = Invoke-KeepAliveWatchdog `
    -GetTask { [pscustomobject]@{ State = 'Running' } } `
    -GetWorkers { @([pscustomobject]@{ ProcessId = 11 }, [pscustomobject]@{ ProcessId = 12 }) } `
    -RegisterTask { $calls.Add('register') } `
    -StartTask { $calls.Add('start') } `
    -StopTask { $calls.Add('stop') } `
    -Wait { param($milliseconds) } `
    -Log { param($message) }
Assert-Equal $result.Action 'DuplicateWorkers' 'Duplicate workers should be reported'
Assert-Sequence $calls @()

'missing main task is recreated and started'
$calls = [System.Collections.Generic.List[string]]::new()
$result = Invoke-KeepAliveWatchdog `
    -GetTask { $null } `
    -GetWorkers { @() } `
    -RegisterTask { $calls.Add('register') } `
    -StartTask { $calls.Add('start') } `
    -StopTask { $calls.Add('stop') } `
    -Wait { param($milliseconds) } `
    -Log { param($message) }
Assert-Equal $result.Action 'Recreated' 'Missing main task should be recreated'
Assert-Sequence $calls @('register', 'start')

'missing task with a live worker is recreated without starting a duplicate'
$calls = [System.Collections.Generic.List[string]]::new()
$result = Invoke-KeepAliveWatchdog `
    -GetTask { $null } `
    -GetWorkers { @([pscustomobject]@{ ProcessId = 11 }) } `
    -RegisterTask { $calls.Add('register') } `
    -StartTask { $calls.Add('start') } `
    -StopTask { $calls.Add('stop') } `
    -Wait { param($milliseconds) } `
    -Log { param($message) }
Assert-Equal $result.Action 'TaskRecreated' 'Live worker should keep the task registration without another start'
Assert-Sequence $calls @('register')

Write-Host 'WATCHDOG TESTS: PASS'
