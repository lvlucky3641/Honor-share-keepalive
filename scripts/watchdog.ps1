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

        [scriptblock]$Wait = {
            param($milliseconds)
            Start-Sleep -Milliseconds $milliseconds
        },

        [scriptblock]$Log = {
            param($message)
        },

        [int]$StopWaitMilliseconds = 750
    )

    $workers = @(& $GetWorkers)
    $task = & $GetTask | Select-Object -First 1
    $workerCount = $workers.Count
    $taskState = if ($task) { [string]$task.State } else { 'Missing' }

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
