$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceRoot = Split-Path -Parent $here
$modulePath = Join-Path $sourceRoot 'VmAutostart.psm1'
$configPath = Join-Path $sourceRoot 'config.psd1'
$fakeVBoxManage = Join-Path $here 'FakeVBoxManage.ps1'

Import-Module $modulePath -Force

Describe 'VM autostart module' {
    BeforeEach {
        $script:config = Import-PowerShellDataFile -LiteralPath $configPath
        $script:fakeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:fakeRoot | Out-Null
        $env:VM_AUTOSTART_FAKE_DIR = $script:fakeRoot
        $env:VM_AUTOSTART_SCENARIO = ''
    }

    AfterEach {
        Remove-Item Env:VM_AUTOSTART_FAKE_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:VM_AUTOSTART_SCENARIO -ErrorAction SilentlyContinue
        Remove-Item Env:VM_AUTOSTART_DELAY_LOG -ErrorAction SilentlyContinue
    }

    It 'stops every configured running VM through the ACPI power button' {
        $result = Stop-ManagedVms -Config $script:config -VBoxManagePath $fakeVBoxManage -DelayAction {}

        @($result).Count | Should Be 3
        foreach ($vmName in $script:config.ManagedVms) {
            $log = @(Get-Content -LiteralPath (Join-Path $script:fakeRoot "$vmName.log"))
            @($log | Where-Object { $_ -eq "controlvm $vmName acpipowerbutton" }).Count | Should Be 1
            ($log -join "`n") | Should Not Match 'savestate'
            ($result | Where-Object VmName -eq $vmName).Action | Should Be 'PoweredOff'
        }
    }

    It 'leaves a powered-off VM alone during Stop and starts it during Start' {
        $env:VM_AUTOSTART_SCENARIO = 'state-poweroff'
        $single = $script:config.Clone(); $single.ManagedVms = @('hub')

        $stopResult = Stop-ManagedVms -Config $single -VBoxManagePath $fakeVBoxManage -DelayAction {}
        $startResult = Start-ManagedVms -Config $single -VBoxManagePath $fakeVBoxManage -DelayAction {}

        $log = @(Get-Content -LiteralPath (Join-Path $script:fakeRoot 'hub.log'))
        @($log | Where-Object { $_ -like 'controlvm*' }).Count | Should Be 0
        @($log | Where-Object { $_ -eq 'startvm hub --type headless' }).Count | Should Be 1
        $stopResult.Action | Should Be 'AlreadyPoweredOff'
        $startResult.Action | Should Be 'Started'
    }

    It 'leaves a saved VM alone during Stop and resumes it during Start' {
        $env:VM_AUTOSTART_SCENARIO = 'state-saved'
        $single = $script:config.Clone(); $single.ManagedVms = @('hub')

        $stopResult = Stop-ManagedVms -Config $single -VBoxManagePath $fakeVBoxManage -DelayAction {}
        $startResult = Start-ManagedVms -Config $single -VBoxManagePath $fakeVBoxManage -DelayAction {}

        $log = @(Get-Content -LiteralPath (Join-Path $script:fakeRoot 'hub.log'))
        @($log | Where-Object { $_ -like 'controlvm*' }).Count | Should Be 0
        @($log | Where-Object { $_ -eq 'startvm hub --type headless' }).Count | Should Be 1
        $stopResult.Action | Should Be 'AlreadySaved'
        $startResult.Action | Should Be 'Started'
    }

    It 'leaves an aborted VM alone during Stop and starts it during Start' {
        $env:VM_AUTOSTART_SCENARIO = 'state-aborted'
        $single = $script:config.Clone(); $single.ManagedVms = @('hub')

        $stopResult = Stop-ManagedVms -Config $single -VBoxManagePath $fakeVBoxManage -DelayAction {}
        $startResult = Start-ManagedVms -Config $single -VBoxManagePath $fakeVBoxManage -DelayAction {}

        $log = @(Get-Content -LiteralPath (Join-Path $script:fakeRoot 'hub.log'))
        @($log | Where-Object { $_ -like 'controlvm*' }).Count | Should Be 0
        @($log | Where-Object { $_ -eq 'startvm hub --type headless' }).Count | Should Be 1
        $stopResult.Action | Should Be 'AlreadyAborted'
        $startResult.Action | Should Be 'Started'
    }

    It 'resumes a paused VM before Stop and leaves it paused during Start' {
        $env:VM_AUTOSTART_SCENARIO = 'state-paused'
        $single = $script:config.Clone(); $single.ManagedVms = @('hub')

        $stopResult = Stop-ManagedVms -Config $single -VBoxManagePath $fakeVBoxManage -DelayAction {}
        Remove-Item -LiteralPath (Join-Path $script:fakeRoot 'hub.acpi')
        Remove-Item -LiteralPath (Join-Path $script:fakeRoot 'hub.resume')
        $startResult = Start-ManagedVms -Config $single -VBoxManagePath $fakeVBoxManage -DelayAction {}

        $log = @(Get-Content -LiteralPath (Join-Path $script:fakeRoot 'hub.log'))
        @($log | Where-Object { $_ -eq 'controlvm hub resume' }).Count | Should Be 1
        @($log | Where-Object { $_ -eq 'controlvm hub acpipowerbutton' }).Count | Should Be 1
        @($log | Where-Object { $_ -eq 'startvm hub --type headless' }).Count | Should Be 0
        $stopResult.Action | Should Be 'PoweredOff'
        $startResult.Action | Should Be 'Paused'
    }

    It 'skips a running VM during Start and logs that state in the result' {
        $env:VM_AUTOSTART_SCENARIO = 'state-running'
        $single = $script:config.Clone(); $single.ManagedVms = @('hub')

        $result = Start-ManagedVms -Config $single -VBoxManagePath $fakeVBoxManage -DelayAction {}

        $log = @(Get-Content -LiteralPath (Join-Path $script:fakeRoot 'hub.log'))
        @($log | Where-Object { $_ -eq 'startvm hub --type headless' }).Count | Should Be 0
        $result.Action | Should Be 'AlreadyRunning'
        $result.Attempts | Should Be 0
    }

    It 'waits on an unusual state during Stop and then saves it' {
        $env:VM_AUTOSTART_SCENARIO = 'stop-unknown'
        $single = $script:config.Clone(); $single.ManagedVms = @('hub'); $single.StopTimeoutSeconds = 10
        $delays = New-Object System.Collections.Generic.List[double]
        $delayAction = { param($Seconds) $delays.Add($Seconds) }.GetNewClosure()

        $result = Stop-ManagedVms -Config $single -VBoxManagePath $fakeVBoxManage -DelayAction $delayAction

        (($delays | Measure-Object -Sum).Sum) | Should Be 10
        $log = @(Get-Content -LiteralPath (Join-Path $script:fakeRoot 'hub.log'))
        @($log | Where-Object { $_ -eq 'controlvm hub acpipowerbutton' }).Count | Should Be 0
        @($log | Where-Object { $_ -eq 'controlvm hub savestate' }).Count | Should Be 1
        $result.Action | Should Be 'SavedState'
    }

    It 'waits on an unusual state during Start and starts it once it becomes startable' {
        $env:VM_AUTOSTART_SCENARIO = 'start-unknown'
        $single = $script:config.Clone(); $single.ManagedVms = @('hub')
        $delays = New-Object System.Collections.Generic.List[double]
        $delayAction = { param($Seconds) $delays.Add($Seconds) }.GetNewClosure()

        $result = Start-ManagedVms -Config $single -VBoxManagePath $fakeVBoxManage -DelayAction $delayAction

        (($delays | Measure-Object -Sum).Sum) | Should Be 10
        $result.Action | Should Be 'Started'
        $result.Attempts | Should Be 1
    }

    It 'saves a VM that is still running after the 120-second stop budget' {
        $env:VM_AUTOSTART_SCENARIO = 'running-ignore-acpi'
        $single = $script:config.Clone(); $single.ManagedVms = @('hub')
        $delayLog = Join-Path $script:fakeRoot 'delays.log'
        $env:VM_AUTOSTART_DELAY_LOG = $delayLog
        $delayAction = { param($Seconds) Add-Content -LiteralPath $env:VM_AUTOSTART_DELAY_LOG -Value $Seconds }

        $result = Stop-ManagedVms -Config $single -VBoxManagePath $fakeVBoxManage -DelayAction $delayAction

        ((Get-Content -LiteralPath $delayLog | Measure-Object -Sum).Sum) | Should Be 120
        $result.Action | Should Be 'SavedState'
        $log = @(Get-Content -LiteralPath (Join-Path $script:fakeRoot 'hub.log'))
        @($log | Where-Object { $_ -eq 'controlvm hub acpipowerbutton' }).Count | Should Be 1
        @($log | Where-Object { $_ -eq 'controlvm hub savestate' }).Count | Should Be 1
    }

    It 'retries an already-locked start every five seconds until it succeeds' {
        $env:VM_AUTOSTART_SCENARIO = 'start-locked'
        $single = $script:config.Clone(); $single.ManagedVms = @('hub')
        $delays = New-Object System.Collections.Generic.List[double]
        $delayAction = { param($Seconds) $delays.Add($Seconds) }.GetNewClosure()

        $result = Start-ManagedVms -Config $single -VBoxManagePath $fakeVBoxManage -DelayAction $delayAction

        $hubLog = @(Get-Content -LiteralPath (Join-Path $script:fakeRoot 'hub.log'))
        @($hubLog | Where-Object { $_ -eq 'startvm hub --type headless' }).Count | Should Be 3
        @($delays).Count | Should Be 2
        (($delays | Measure-Object -Sum).Sum) | Should Be 10
        $result.Attempts | Should Be 3
    }

    It 'treats a timed-out status check as still running and falls through to save' {
        $env:VM_AUTOSTART_SCENARIO = 'hung-status'
        $single = $script:config.Clone(); $single.ManagedVms = @('hub')
        $single.StopTimeoutSeconds = 0; $single.StatusCallTimeoutSeconds = 0.2

        $result = Stop-ManagedVms -Config $single -VBoxManagePath $fakeVBoxManage -DelayAction {}

        $result.Action | Should Be 'SavedState'
        $log = @(Get-Content -LiteralPath (Join-Path $script:fakeRoot 'hub.log'))
        @($log | Where-Object { $_ -eq 'controlvm hub acpipowerbutton' }).Count | Should Be 1
        @($log | Where-Object { $_ -eq 'controlvm hub savestate' }).Count | Should Be 1
    }

    It 'does not save a VM found powered off in the final status check' {
        $env:VM_AUTOSTART_SCENARIO = 'final-off'
        $single = $script:config.Clone(); $single.ManagedVms = @('hub'); $single.StopTimeoutSeconds = 0

        $result = Stop-ManagedVms -Config $single -VBoxManagePath $fakeVBoxManage -DelayAction {}

        $result.Action | Should Be 'AlreadyPoweredOff'
        $log = @(Get-Content -LiteralPath (Join-Path $script:fakeRoot 'hub.log'))
        @($log | Where-Object { $_ -eq 'controlvm hub savestate' }).Count | Should Be 0
    }

    It 'uses the configured status, control, start and save call limits' {
        $script:config.StatusCallTimeoutSeconds | Should Be 30
        $script:config.ControlCallTimeoutSeconds | Should Be 30
        $script:config.StartCallTimeoutSeconds | Should Be 30
        $script:config.SaveStateCallTimeoutSeconds | Should Be 600
    }

    It 'enforces the control-call limit' {
        $env:VM_AUTOSTART_SCENARIO = 'hung-control'
        $single = $script:config.Clone(); $single.ManagedVms = @('hub')
        $single.StopTimeoutSeconds = 0; $single.ControlCallTimeoutSeconds = 0.2

        $result = Stop-ManagedVms -Config $single -VBoxManagePath $fakeVBoxManage -DelayAction {}

        $result.Action | Should Be 'SavedState'
        $result.Error | Should Match 'timed out.*acpipowerbutton|acpipowerbutton.*timed out'
    }

    It 'enforces the save-state call limit' {
        $env:VM_AUTOSTART_SCENARIO = 'hung-save'
        $single = $script:config.Clone(); $single.ManagedVms = @('hub')
        $single.StopTimeoutSeconds = 0; $single.SaveStateCallTimeoutSeconds = 0.2

        $result = Stop-ManagedVms -Config $single -VBoxManagePath $fakeVBoxManage -DelayAction {}

        $result.Action | Should Be 'Failed'
        $result.Error | Should Match 'timed out.*savestate|savestate.*timed out'
    }

    It 'continues other VMs through shutdown and saves the VM whose ACPI request failed' {
        $env:VM_AUTOSTART_SCENARIO = 'one-control-failure'
        $single = $script:config.Clone(); $single.StopTimeoutSeconds = 0

        $result = Stop-ManagedVms -Config $single -VBoxManagePath $fakeVBoxManage -DelayAction {}

        ($result | Where-Object VmName -eq 'hub').Action | Should Be 'SavedState'
        ($result | Where-Object VmName -eq 'hub').Error | Should Match 'Fake ACPI failure'
        @($result | Where-Object Action -eq 'PoweredOff').Count | Should Be 2
        foreach ($vmName in $single.ManagedVms) {
            $log = @(Get-Content -LiteralPath (Join-Path $script:fakeRoot "$vmName.log"))
            @($log | Where-Object { $_ -eq "controlvm $vmName acpipowerbutton" }).Count | Should Be 1
        }
        $hubLog = @(Get-Content -LiteralPath (Join-Path $script:fakeRoot 'hub.log'))
        @($hubLog | Where-Object { $_ -eq 'controlvm hub savestate' }).Count | Should Be 1
    }

    It 'records a repeated status error only once for a VM' {
        $env:VM_AUTOSTART_SCENARIO = 'repeated-status-error'
        $single = $script:config.Clone(); $single.ManagedVms = @('hub'); $single.StopTimeoutSeconds = 10

        $result = Stop-ManagedVms -Config $single -VBoxManagePath $fakeVBoxManage -DelayAction {}

        $result.Action | Should Be 'SavedState'
        ([regex]::Matches($result.Error, "Fake repeated status failure for 'hub'\.")).Count | Should Be 1
    }

    It 'enforces the start-call limit' {
        $env:VM_AUTOSTART_SCENARIO = 'hung-start'
        $single = $script:config.Clone(); $single.ManagedVms = @('hub'); $single.StartCallTimeoutSeconds = 0.2

        { Start-ManagedVms -Config $single -VBoxManagePath $fakeVBoxManage -DelayAction {} } | Should Throw
    }

    It 'keeps a slow state check and start call inside the overall start budget' {
        $env:VM_AUTOSTART_SCENARIO = 'slow-status-start'
        $single = $script:config.Clone(); $single.ManagedVms = @('hub')
        $single.StartTimeoutSeconds = 1.5; $single.StartCallTimeoutSeconds = 30
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()

        { Start-ManagedVms -Config $single -VBoxManagePath $fakeVBoxManage -DelayAction {} } | Should Throw
        $stopwatch.Stop()

        $stopwatch.Elapsed.TotalSeconds | Should BeLessThan 2.2
    }

    It 'dispatches stop and start commands concurrently' {
        $env:VM_AUTOSTART_SCENARIO = 'parallel-stop'
        Stop-ManagedVms -Config $script:config -VBoxManagePath $fakeVBoxManage -DelayAction {} | Out-Null
        $env:VM_AUTOSTART_SCENARIO = 'parallel-start'
        Start-ManagedVms -Config $script:config -VBoxManagePath $fakeVBoxManage -DelayAction {} | Out-Null

        @(Get-ChildItem -LiteralPath $script:fakeRoot -Filter 'stop-*.ready').Count | Should Be 3
        @(Get-ChildItem -LiteralPath $script:fakeRoot -Filter 'start-*.ready').Count | Should Be 3
    }

    It 'drains large VBoxManage output without deadlocking' {
        $env:VM_AUTOSTART_SCENARIO = 'large-output'

        $result = Stop-ManagedVms -Config $script:config -VBoxManagePath $fakeVBoxManage -DelayAction {}

        @($result).Count | Should Be 3
        @($result | Where-Object Action -eq 'AlreadyPoweredOff').Count | Should Be 3
    }
}
