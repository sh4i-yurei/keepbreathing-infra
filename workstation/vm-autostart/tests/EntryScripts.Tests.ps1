$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceRoot = Split-Path -Parent $here
$startupScript = Join-Path $sourceRoot 'startup.ps1'
$stopScript = Join-Path $sourceRoot 'stop.ps1'

Describe 'VM autostart entry scripts' {
    BeforeEach {
        $script:caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $script:logRoot = Join-Path $script:caseRoot 'logs'
        New-Item -ItemType Directory -Path $script:caseRoot | Out-Null
    }

    It 'logs the actual result and attempt count for every managed VM' {
        $startAction = {
            @(
                [pscustomobject]@{ VmName = 'first'; Action = 'Started'; Attempts = 2 }
                [pscustomobject]@{ VmName = 'second'; Action = 'AlreadyRunning'; Attempts = 0 }
                [pscustomobject]@{ VmName = 'third'; Action = 'Paused'; Attempts = 0 }
            )
        }

        & $startupScript -StartAction $startAction -LogDirectory $script:logRoot | Out-Null

        $log = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $script:logRoot -Filter '*.log').FullName -Raw
        $log | Should Match "VM 'first' start result: Started after 2 attempt"
        $log | Should Match "VM 'second' start result: AlreadyRunning after 0 attempt"
        $log | Should Match "VM 'third' start result: Paused after 0 attempt"
        $log | Should Match 'Processed 3 managed VMs'
    }

    It 'logs an action failure before returning the error' {
        $caught = $false
        try {
            & $startupScript -StartAction { throw 'fake start failure' } -LogDirectory $script:logRoot
        }
        catch { $caught = $true }

        $caught | Should Be $true
        $log = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $script:logRoot -Filter '*.log').FullName -Raw
        $log | Should Match 'Failed: fake start failure'
    }

    It 'logs a malformed configuration file as a runtime load failure' {
        $runtimeRoot = Join-Path $script:caseRoot 'runtime'
        New-Item -ItemType Directory -Path $runtimeRoot | Out-Null
        foreach ($fileName in @('startup.ps1', 'EntryPoint.Common.ps1', 'VmAutostart.psm1')) {
            Copy-Item -LiteralPath (Join-Path $sourceRoot $fileName) -Destination $runtimeRoot
        }
        Set-Content -LiteralPath (Join-Path $runtimeRoot 'config.psd1') -Value '@{ broken = '
        $runtimeStartup = Join-Path $runtimeRoot 'startup.ps1'
        $caught = $false

        try { & $runtimeStartup -LogDirectory $script:logRoot }
        catch { $caught = $true }

        $caught | Should Be $true
        $log = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $script:logRoot -Filter '*.log').FullName -Raw
        $log | Should Match '\[startup\] Failed:'
    }

    It 'logs every stop result and calls out a save fallback' {
        $stopAction = {
            @(
                [pscustomobject]@{ VmName = 'first'; Action = 'PoweredOff'; ElapsedSeconds = 12.3 }
                [pscustomobject]@{ VmName = 'second'; Action = 'SavedState'; ElapsedSeconds = 120 }
            )
        }

        & $stopScript -StopAction $stopAction -LogDirectory $script:logRoot | Out-Null

        $log = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $script:logRoot -Filter '*.log').FullName -Raw
        $log | Should Match "VM 'first' stop result: PoweredOff after 12.3 seconds"
        $log | Should Match "Warning: VM 'second' stop result: SavedState after 120 seconds"
        $log | Should Match 'Stop completed for 2 managed VMs'
    }

    It 'logs a stop failure before returning the error' {
        $caught = $false
        try { & $stopScript -StopAction { throw 'fake stop failure' } -LogDirectory $script:logRoot }
        catch { $caught = $true }

        $caught | Should Be $true
        $log = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $script:logRoot -Filter '*.log').FullName -Raw
        $log | Should Match 'Failed: fake stop failure'
    }

    It 'logs every module result before failing a stop with a failed VM' {
        $caught = $false
        $stopAction = {
            @(
                [pscustomobject]@{ VmName = 'first'; Action = 'PoweredOff'; ElapsedSeconds = 10; Error = $null }
                [pscustomobject]@{ VmName = 'second'; Action = 'Failed'; ElapsedSeconds = 12; Error = 'fake save failure' }
            )
        }

        try { & $stopScript -StopAction $stopAction -LogDirectory $script:logRoot }
        catch { $caught = $true }

        $caught | Should Be $true
        $log = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $script:logRoot -Filter '*.log').FullName -Raw
        $log | Should Match "VM 'first' stop result: PoweredOff"
        $log | Should Match "Failure: VM 'second' stop result: Failed"
        $log | Should Match 'Detail: fake save failure'
        $log | Should Match 'Failed: Stop failed for: second'
    }
}
