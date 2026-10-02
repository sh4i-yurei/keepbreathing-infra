Set-StrictMode -Version Latest

function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory = $true)][string] $Value)

    if ($Value -notmatch '[\s"]') { return $Value }
    '"{0}"' -f ($Value -replace '(\\*)"', '$1$1\"')
}

function Start-VBoxManageProcess {
    param(
        [Parameter(Mandatory = $true)][string] $VBoxManagePath,
        [Parameter(Mandatory = $true)][string[]] $ArgumentList,
        [Parameter(Mandatory = $true)][string] $VmName
    )

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    if ([IO.Path]::GetExtension($VBoxManagePath) -eq '.ps1') {
        $processInfo.FileName = 'powershell.exe'
        $allArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $VBoxManagePath) + $ArgumentList
    }
    else {
        $processInfo.FileName = $VBoxManagePath
        $allArguments = $ArgumentList
    }
    $processInfo.Arguments = (($allArguments | ForEach-Object { ConvertTo-ProcessArgument -Value $_ }) -join ' ')
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo
    if (-not $process.Start()) { throw "Could not start VBoxManage for '$VmName'." }

    [pscustomobject]@{
        VmName             = $VmName
        Arguments          = $ArgumentList
        Process            = $process
        StandardOutputTask = $process.StandardOutput.ReadToEndAsync()
        StandardErrorTask  = $process.StandardError.ReadToEndAsync()
    }
}

function Complete-VBoxManageProcess {
    param(
        [Parameter(Mandatory = $true)][psobject] $Invocation,
        [Parameter(Mandatory = $true)][int] $TimeoutMilliseconds
    )

    $timedOut = -not $Invocation.Process.WaitForExit($TimeoutMilliseconds)
    if ($timedOut) {
        try { $Invocation.Process.Kill() }
        catch { if (-not $Invocation.Process.HasExited) { throw } }
        $Invocation.Process.WaitForExit()
    }

    $standardOutput = $Invocation.StandardOutputTask.GetAwaiter().GetResult()
    $standardError = $Invocation.StandardErrorTask.GetAwaiter().GetResult()
    $exitCode = if ($timedOut) { $null } else { $Invocation.Process.ExitCode }
    $Invocation.Process.Dispose()

    [pscustomobject]@{
        VmName         = $Invocation.VmName
        Arguments      = $Invocation.Arguments
        ExitCode       = $exitCode
        TimedOut       = $timedOut
        TimeoutSeconds = $TimeoutMilliseconds / 1000
        StandardOutput = $standardOutput
        StandardError  = $standardError
    }
}

function Invoke-VBoxManageConcurrent {
    param(
        [Parameter(Mandatory = $true)][string] $VBoxManagePath,
        [Parameter(Mandatory = $true)][hashtable[]] $Commands,
        [Parameter(Mandatory = $true)][double] $TimeoutSeconds
    )

    if ($Commands.Count -eq 0) { return @() }
    $running = @($Commands | ForEach-Object {
            Start-VBoxManageProcess -VBoxManagePath $VBoxManagePath -ArgumentList $_.Arguments -VmName $_.VmName
        })
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    @($running | ForEach-Object {
            $remainingMilliseconds = [Math]::Max(
                1,
                [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            )
            Complete-VBoxManageProcess -Invocation $_ -TimeoutMilliseconds $remainingMilliseconds
        })
}

function Assert-VBoxManageSucceeded {
    param([Parameter(Mandatory = $true)][psobject] $Result)

    if ($Result.TimedOut) {
        throw "VBoxManage $($Result.Arguments -join ' ') timed out for '$($Result.VmName)' after $($Result.TimeoutSeconds) seconds."
    }
    if ($Result.ExitCode -eq 0) { return }

    $detail = $Result.StandardError.Trim()
    if (-not $detail) { $detail = $Result.StandardOutput.Trim() }
    throw "VBoxManage $($Result.Arguments -join ' ') failed for '$($Result.VmName)' with exit code $($Result.ExitCode): $detail"
}

function Get-VmState {
    param([Parameter(Mandatory = $true)][psobject] $Result)

    Assert-VBoxManageSucceeded -Result $Result
    $match = [regex]::Match($Result.StandardOutput, '(?m)^VMState="(?<state>[^"]+)"\s*$')
    if (-not $match.Success) { throw "VBoxManage did not report VMState for '$($Result.VmName)'." }
    $match.Groups['state'].Value
}

function Get-VmStates {
    param(
        [Parameter(Mandatory = $true)][string] $VBoxManagePath,
        [Parameter(Mandatory = $true)][string[]] $VmNames,
        [Parameter(Mandatory = $true)][double] $TimeoutSeconds
    )

    $results = Invoke-VBoxManageConcurrent -VBoxManagePath $VBoxManagePath -TimeoutSeconds $TimeoutSeconds -Commands @(
        $VmNames | ForEach-Object { @{ VmName = $_; Arguments = @('showvminfo', $_, '--machinereadable') } }
    )
    @($results | ForEach-Object {
            $state = $null
            $errorMessage = $null
            if (-not $_.TimedOut) {
                try { $state = Get-VmState -Result $_ }
                catch { $errorMessage = $_.Exception.Message }
            }
            [pscustomobject]@{
                VmName   = $_.VmName
                State    = $state
                TimedOut = $_.TimedOut
                Error    = $errorMessage
            }
        })
}

function Add-VmStopError {
    param(
        [Parameter(Mandatory = $true)][hashtable] $ErrorsByVm,
        [Parameter(Mandatory = $true)][string] $VmName,
        [Parameter(Mandatory = $true)][string] $Message
    )

    if (-not $ErrorsByVm.ContainsKey($VmName)) {
        $ErrorsByVm[$VmName] = New-Object System.Collections.Generic.List[string]
    }
    if (-not $ErrorsByVm[$VmName].Contains($Message)) {
        $ErrorsByVm[$VmName].Add($Message)
    }
}

function Get-BudgetElapsedSeconds {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Stopwatch] $Stopwatch,
        [Parameter(Mandatory = $true)][double] $ScheduledElapsedSeconds
    )
    [Math]::Max($ScheduledElapsedSeconds, $Stopwatch.Elapsed.TotalSeconds)
}

function Set-TerminalStopResult {
    param(
        [Parameter(Mandatory = $true)][string] $VmName,
        [Parameter(Mandatory = $true)][string] $State,
        [Parameter(Mandatory = $true)][hashtable] $Actions,
        [Parameter(Mandatory = $true)][hashtable] $ElapsedByVm,
        [Parameter(Mandatory = $true)][hashtable] $StopRequested,
        [Parameter(Mandatory = $true)][double] $ElapsedSeconds
    )

    switch ($State) {
        'poweroff' { $Actions[$VmName] = if ($StopRequested[$VmName]) { 'PoweredOff' } else { 'AlreadyPoweredOff' } }
        'saved' { $Actions[$VmName] = 'AlreadySaved' }
        'aborted' { $Actions[$VmName] = 'AlreadyAborted' }
        default { return $false }
    }
    $ElapsedByVm[$VmName] = [Math]::Round($ElapsedSeconds, 1)
    $true
}

function Stop-ManagedVms {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable] $Config,
        [string] $VBoxManagePath = $Config.VBoxManagePath,
        [scriptblock] $DelayAction = { param($Seconds) Start-Sleep -Seconds $Seconds }
    )

    $actions = @{}
    $elapsedByVm = @{}
    $stopRequested = @{}
    $errorsByVm = @{}
    $pending = New-Object System.Collections.Generic.List[string]
    $running = New-Object System.Collections.Generic.List[string]
    $paused = New-Object System.Collections.Generic.List[string]

    $initialStates = Get-VmStates -VBoxManagePath $VBoxManagePath -VmNames $Config.ManagedVms `
        -TimeoutSeconds $Config.StatusCallTimeoutSeconds
    foreach ($stateResult in $initialStates) {
        if ($stateResult.Error) {
            Add-VmStopError -ErrorsByVm $errorsByVm -VmName $stateResult.VmName `
                -Message $stateResult.Error
        }
        if ($stateResult.State -and (Set-TerminalStopResult -VmName $stateResult.VmName -State $stateResult.State `
                    -Actions $actions -ElapsedByVm $elapsedByVm -StopRequested $stopRequested -ElapsedSeconds 0)) {
            continue
        }
        $pending.Add($stateResult.VmName)
        if ($stateResult.State -eq 'running' -or $stateResult.TimedOut) { $running.Add($stateResult.VmName) }
        if ($stateResult.State -eq 'paused') { $paused.Add($stateResult.VmName) }
    }

    if ($paused.Count -gt 0) {
        $resumeResults = Invoke-VBoxManageConcurrent -VBoxManagePath $VBoxManagePath `
            -TimeoutSeconds $Config.ControlCallTimeoutSeconds -Commands @(
            $paused | ForEach-Object { @{ VmName = $_; Arguments = @('controlvm', $_, 'resume') } }
        )
        $resumed = New-Object System.Collections.Generic.List[string]
        $resumeResults | ForEach-Object {
            $result = $_
            try {
                Assert-VBoxManageSucceeded -Result $result
                $resumed.Add($result.VmName)
            }
            catch {
                Add-VmStopError -ErrorsByVm $errorsByVm -VmName $result.VmName `
                    -Message $_.Exception.Message
            }
        }
    }
    else { $resumed = @() }

    $vmsToSignal = @($running) + @($resumed)
    if ($vmsToSignal.Count -gt 0) {
        $stopResults = Invoke-VBoxManageConcurrent -VBoxManagePath $VBoxManagePath `
            -TimeoutSeconds $Config.ControlCallTimeoutSeconds -Commands @(
            $vmsToSignal | ForEach-Object { @{ VmName = $_; Arguments = @('controlvm', $_, 'acpipowerbutton') } }
        )
        $stopResults | ForEach-Object {
            $result = $_
            $stopRequested[$result.VmName] = $true
            try { Assert-VBoxManageSucceeded -Result $result }
            catch {
                Add-VmStopError -ErrorsByVm $errorsByVm -VmName $result.VmName `
                    -Message $_.Exception.Message
            }
        }
    }

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $scheduledElapsedSeconds = 0.0
    while ($pending.Count -gt 0) {
        $elapsedSeconds = Get-BudgetElapsedSeconds -Stopwatch $stopwatch -ScheduledElapsedSeconds $scheduledElapsedSeconds
        $remainingSeconds = $Config.StopTimeoutSeconds - $elapsedSeconds
        if ($remainingSeconds -le 0) { break }

        $queryTimeout = [Math]::Min($Config.StatusCallTimeoutSeconds, $remainingSeconds)
        $stateResults = Get-VmStates -VBoxManagePath $VBoxManagePath -VmNames @($pending) -TimeoutSeconds $queryTimeout
        $stillPending = New-Object System.Collections.Generic.List[string]
        foreach ($stateResult in $stateResults) {
            if ($stateResult.Error) {
                Add-VmStopError -ErrorsByVm $errorsByVm -VmName $stateResult.VmName `
                    -Message $stateResult.Error
            }
            $elapsedNow = Get-BudgetElapsedSeconds -Stopwatch $stopwatch -ScheduledElapsedSeconds $scheduledElapsedSeconds
            if (-not $stateResult.State -or -not (Set-TerminalStopResult -VmName $stateResult.VmName `
                        -State $stateResult.State -Actions $actions -ElapsedByVm $elapsedByVm `
                        -StopRequested $stopRequested -ElapsedSeconds $elapsedNow)) {
                $stillPending.Add($stateResult.VmName)
            }
        }
        $pending = $stillPending
        if ($pending.Count -eq 0) { break }

        $elapsedSeconds = Get-BudgetElapsedSeconds -Stopwatch $stopwatch -ScheduledElapsedSeconds $scheduledElapsedSeconds
        $delaySeconds = [Math]::Min($Config.RetryIntervalSeconds, $Config.StopTimeoutSeconds - $elapsedSeconds)
        if ($delaySeconds -le 0) { break }
        & $DelayAction $delaySeconds
        $scheduledElapsedSeconds += $delaySeconds
    }
    $stopwatch.Stop()

    if ($pending.Count -gt 0) {
        $finalStates = Get-VmStates -VBoxManagePath $VBoxManagePath -VmNames @($pending) `
            -TimeoutSeconds $Config.StatusCallTimeoutSeconds
        $vmsToSave = New-Object System.Collections.Generic.List[string]
        foreach ($stateResult in $finalStates) {
            if ($stateResult.Error) {
                Add-VmStopError -ErrorsByVm $errorsByVm -VmName $stateResult.VmName `
                    -Message $stateResult.Error
            }
            $elapsedNow = Get-BudgetElapsedSeconds -Stopwatch $stopwatch -ScheduledElapsedSeconds $scheduledElapsedSeconds
            if (-not $stateResult.State -or -not (Set-TerminalStopResult -VmName $stateResult.VmName `
                        -State $stateResult.State -Actions $actions -ElapsedByVm $elapsedByVm `
                        -StopRequested $stopRequested -ElapsedSeconds $elapsedNow)) {
                $vmsToSave.Add($stateResult.VmName)
            }
        }

        if ($vmsToSave.Count -gt 0) {
            $saveResults = Invoke-VBoxManageConcurrent -VBoxManagePath $VBoxManagePath `
                -TimeoutSeconds $Config.SaveStateCallTimeoutSeconds -Commands @(
                $vmsToSave | ForEach-Object { @{ VmName = $_; Arguments = @('controlvm', $_, 'savestate') } }
            )
            $saveResults | ForEach-Object {
                $result = $_
                $elapsedByVm[$result.VmName] = [Math]::Round(
                    (Get-BudgetElapsedSeconds -Stopwatch $stopwatch -ScheduledElapsedSeconds $scheduledElapsedSeconds), 1)
                try {
                    Assert-VBoxManageSucceeded -Result $result
                    $actions[$result.VmName] = 'SavedState'
                }
                catch {
                    $actions[$result.VmName] = 'Failed'
                    Add-VmStopError -ErrorsByVm $errorsByVm -VmName $result.VmName `
                        -Message $_.Exception.Message
                }
            }
        }
    }

    @($Config.ManagedVms | ForEach-Object {
            $errorMessage = if ($errorsByVm.ContainsKey($_)) { $errorsByVm[$_] -join '; ' } else { $null }
            [pscustomobject]@{
                VmName = $_
                Action = $actions[$_]
                ElapsedSeconds = $elapsedByVm[$_]
                Error = $errorMessage
            }
        })
}

function Start-ManagedVms {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable] $Config,
        [string] $VBoxManagePath = $Config.VBoxManagePath,
        [scriptblock] $DelayAction = { param($Seconds) Start-Sleep -Seconds $Seconds }
    )

    $pending = @($Config.ManagedVms)
    $attempts = @{}
    $actions = @{}
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $scheduledElapsedSeconds = 0.0

    while ($pending.Count -gt 0) {
        $elapsedSeconds = Get-BudgetElapsedSeconds -Stopwatch $stopwatch -ScheduledElapsedSeconds $scheduledElapsedSeconds
        $remainingSeconds = $Config.StartTimeoutSeconds - $elapsedSeconds
        if ($remainingSeconds -le 0) {
            throw "VBoxManage could not start within $($Config.StartTimeoutSeconds) seconds: $($pending -join ', ')."
        }

        $queryTimeout = [Math]::Min($Config.StatusCallTimeoutSeconds, $remainingSeconds)
        $stateResults = Get-VmStates -VBoxManagePath $VBoxManagePath -VmNames $pending -TimeoutSeconds $queryTimeout
        $elapsedSeconds = Get-BudgetElapsedSeconds -Stopwatch $stopwatch -ScheduledElapsedSeconds $scheduledElapsedSeconds
        $remainingSeconds = $Config.StartTimeoutSeconds - $elapsedSeconds
        if ($remainingSeconds -le 0) {
            throw "VBoxManage could not start within $($Config.StartTimeoutSeconds) seconds: $($pending -join ', ')."
        }
        $nextPending = New-Object System.Collections.Generic.List[string]
        $vmsToStart = New-Object System.Collections.Generic.List[string]
        foreach ($stateResult in $stateResults) {
            switch ($stateResult.State) {
                'running' {
                    $actions[$stateResult.VmName] = 'AlreadyRunning'
                    $attempts[$stateResult.VmName] = 0
                }
                'paused' {
                    $actions[$stateResult.VmName] = 'Paused'
                    $attempts[$stateResult.VmName] = 0
                }
                'poweroff' { $vmsToStart.Add($stateResult.VmName) }
                'saved' { $vmsToStart.Add($stateResult.VmName) }
                'aborted' { $vmsToStart.Add($stateResult.VmName) }
                default { $nextPending.Add($stateResult.VmName) }
            }
        }

        if ($vmsToStart.Count -gt 0) {
            foreach ($vmName in $vmsToStart) {
                if (-not $attempts.ContainsKey($vmName)) { $attempts[$vmName] = 0 }
                $attempts[$vmName]++
            }
            $startTimeout = [Math]::Min($Config.StartCallTimeoutSeconds, $remainingSeconds)
            $startResults = Invoke-VBoxManageConcurrent -VBoxManagePath $VBoxManagePath `
                -TimeoutSeconds $startTimeout -Commands @(
                $vmsToStart | ForEach-Object { @{ VmName = $_; Arguments = @('startvm', $_, '--type', 'headless') } }
            )
            foreach ($result in $startResults) {
                if ($result.ExitCode -eq 0 -and -not $result.TimedOut) {
                    $actions[$result.VmName] = 'Started'
                    continue
                }
                $combinedOutput = "$($result.StandardOutput)`n$($result.StandardError)"
                if (-not $result.TimedOut -and $combinedOutput -match 'already locked by a session') {
                    $nextPending.Add($result.VmName)
                    continue
                }
                Assert-VBoxManageSucceeded -Result $result
            }
        }

        $pending = @($nextPending)
        if ($pending.Count -eq 0) { break }
        $elapsedSeconds = Get-BudgetElapsedSeconds -Stopwatch $stopwatch -ScheduledElapsedSeconds $scheduledElapsedSeconds
        $delaySeconds = [Math]::Min($Config.RetryIntervalSeconds, $Config.StartTimeoutSeconds - $elapsedSeconds)
        if ($delaySeconds -le 0) {
            throw "VBoxManage could not start within $($Config.StartTimeoutSeconds) seconds: $($pending -join ', ')."
        }
        & $DelayAction $delaySeconds
        $scheduledElapsedSeconds += $delaySeconds
    }
    $stopwatch.Stop()

    @($Config.ManagedVms | ForEach-Object {
            [pscustomobject]@{ VmName = $_; Action = $actions[$_]; Attempts = $attempts[$_] }
        })
}

Export-ModuleMember -Function Stop-ManagedVms, Start-ManagedVms
