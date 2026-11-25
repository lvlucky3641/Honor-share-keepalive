function Test-KeepAliveTaskCommand {
    param(
        $Task,
        [string]$ExpectedExecutable,
        [string]$ExpectedLauncher
    )

    if (-not $Task) {
        return $false
    }

    $actions = @($Task.Actions)
    if ($actions.Count -ne 1 -or -not $actions[0].Execute -or -not $actions[0].Arguments) {
        return $false
    }

    return (
        [string]::Equals(
            $actions[0].Execute,
            $ExpectedExecutable,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -and
        $actions[0].Arguments.IndexOf(
            $ExpectedLauncher,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -ge 0
    )
}

function Get-KeepAliveWatchdogTaskAction {
    param(
        [Parameter(Mandatory)]
        [string]$WScript,

        [Parameter(Mandatory)]
        [string]$Launcher
    )

    return [pscustomobject]@{
        Execute = $WScript
        Arguments = "//B //NoLogo `"$Launcher`""
    }
}

function Invoke-KeepAliveWatchdog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$GetTask,

        [Parameter(Mandatory)]
        [scriptblock]$GetWorkers,

        [Parameter(Mandatory)]
        [scriptblock]$RegisterTask,

        [Parameter(Mandatory)]
        [scriptblock]$StartTask,

        [Parameter(Mandatory)]
        [scriptblock]$StopTask,

        [Parameter(Mandatory)]
        [string]$ExpectedWorkerScript,

        [Parameter(Mandatory)]
        [scriptblock]$StopAllWorkers,

        [scriptblock]$Wait = {
            param($milliseconds)
            Start-Sleep -Milliseconds $milliseconds
        },

        [scriptblock]$Log = {
            param($message)
        },

        [int]$StopWaitMilliseconds = 750
    )

    $allWorkers = @(& $GetWorkers)
    $workers = @(
        $allWorkers | Where-Object {
            $_.CommandLine -and
            $_.CommandLine.IndexOf(
                $ExpectedWorkerScript,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        }
    )
    $foreignWorkers = @(
        $allWorkers | Where-Object {
            -not $_.CommandLine -or
            $_.CommandLine.IndexOf(
                $ExpectedWorkerScript,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -lt 0
        }
    )
    $task = & $GetTask | Select-Object -First 1
    $workerCount = $workers.Count
    $taskState = if ($task) { [string]$task.State } else { 'Missing' }

    if ($foreignWorkers.Count -gt 0) {
        & $Log "Detected $($foreignWorkers.Count) worker(s) from another installation; migrating to $ExpectedWorkerScript."
        & $StopAllWorkers
        & $RegisterTask
        & $StartTask
        return [pscustomobject]@{
            Action = 'Migrated'
            WorkerCount = $workerCount
            ForeignWorkerCount = $foreignWorkers.Count
            TaskState = $taskState
        }
    }

    if ($workerCount -gt 1) {
        & $Log "Detected $workerCount keepalive workers; skipping automatic recovery."
        return [pscustomobject]@{
            Action = 'DuplicateWorkers'
            WorkerCount = $workerCount
            TaskState = $taskState
        }
    }

    if ($workerCount -eq 1) {
        if (-not $task) {
            & $Log 'Worker is alive but the scheduled task is missing; recreating it.'
            & $RegisterTask
            return [pscustomobject]@{
                Action = 'TaskRecreated'
                WorkerCount = 1
                TaskState = 'Missing'
            }
        }

        return [pscustomobject]@{
            Action = 'Healthy'
            WorkerCount = 1
            TaskState = $taskState
        }
    }

    if (-not $task) {
        & $Log 'Worker and scheduled task are missing; recreating and starting them.'
        & $RegisterTask
        & $StartTask
        return [pscustomobject]@{
            Action = 'Recreated'
            WorkerCount = 0
            TaskState = 'Missing'
        }
    }

    if ($taskState -eq 'Running') {
        & $Log 'Task is marked Running but the worker is missing; restarting it.'
        & $StopTask
        & $Wait $StopWaitMilliseconds
        & $StartTask
        return [pscustomobject]@{
            Action = 'Restarted'
            WorkerCount = 0
            TaskState = 'Running'
        }
    }

    & $Log "Worker is missing and task state is $taskState; starting it."
    & $StartTask
    return [pscustomobject]@{
        Action = 'Started'
        WorkerCount = 0
        TaskState = $taskState
    }
}
