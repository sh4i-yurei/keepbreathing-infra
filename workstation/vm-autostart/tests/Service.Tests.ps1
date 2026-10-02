$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceRoot = Split-Path -Parent $here
$installScript = Join-Path $sourceRoot 'install.ps1'
$fakeVBoxManage = Join-Path $here 'FakeVBoxManage.ps1'
. $installScript -FunctionsOnly -DestinationRoot 'C:\ProgramData\keepbreathing\vm-autostart'

Describe 'VM autostop service console path' {
    BeforeEach {
        $script:runtimeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $script:fakeRoot = Join-Path $script:runtimeRoot 'fake'
        New-Item -ItemType Directory -Path $script:runtimeRoot | Out-Null
        New-Item -ItemType Directory -Path $script:fakeRoot | Out-Null
        foreach ($fileName in @('VmAutostart.psm1', 'EntryPoint.Common.ps1', 'stop.ps1')) {
            Copy-Item -LiteralPath (Join-Path $sourceRoot $fileName) -Destination $script:runtimeRoot
        }
        $escapedFakePath = $fakeVBoxManage.Replace("'", "''")
        $config = @"
@{
    ManagedVms = @('AlmaServ', 'VaultServ', 'hub')
    VBoxManagePath = '$escapedFakePath'
    StopTimeoutSeconds = 120
    StartTimeoutSeconds = 60
    RetryIntervalSeconds = 5
    StatusCallTimeoutSeconds = 30
    ControlCallTimeoutSeconds = 30
    StartCallTimeoutSeconds = 30
    SaveStateCallTimeoutSeconds = 600
}
"@
        Set-Content -LiteralPath (Join-Path $script:runtimeRoot 'config.psd1') -Value $config
        $env:VM_AUTOSTART_FAKE_DIR = $script:fakeRoot
        $env:VM_AUTOSTART_SCENARIO = ''
    }

    AfterEach {
        Remove-Item Env:VM_AUTOSTART_FAKE_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:VM_AUTOSTART_SCENARIO -ErrorAction SilentlyContinue
    }

    It 'runs the Stop entry point and ends reporting stopped against fake VBoxManage' {
        $executable = Join-Path $script:runtimeRoot 'VmAutostopService.exe'
        Compile-VmAutostopService -SourcePath (Join-Path $sourceRoot 'VmAutostopService.cs') `
            -OutputPath $executable

        $output = @(& $executable --console-stop (Join-Path $script:runtimeRoot 'stop.ps1') 2>&1)

        $LASTEXITCODE | Should Be 0
        ($output -join "`n") | Should Match 'SERVICE_STOP_PENDING'
        $output[-1] | Should Be 'SERVICE_STOPPED'
        $assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($executable))
        $type = $assembly.GetType('VmAutostopServiceConfiguration', $true, $false)
        $logonRightAccount = $type.GetMethod('GetServiceLogonRightAccountName').Invoke(
            $null, @('.\DELL'))
        $logonRightAccount | Should Be "$env:COMPUTERNAME\DELL"
        $resolvedSid = $type.GetMethod('ResolveAccountSid').Invoke($null, @($logonRightAccount))
        $expectedSid = (New-Object Security.Principal.NTAccount(
                "$env:COMPUTERNAME\DELL")).Translate(
            [Security.Principal.SecurityIdentifier]).Value
        $resolvedSid | Should Be $expectedSid
        $commands = @(Get-ChildItem -LiteralPath $script:fakeRoot -Filter '*.log' |
            Get-Content | Where-Object { $_ -match 'acpipowerbutton$' })
        $commands.Count | Should Be 3
    }

    It 'reports an ordinary service stop without running the Stop entry point' {
        $executable = Join-Path $script:runtimeRoot 'VmAutostopService.exe'
        $markerPath = Join-Path $script:runtimeRoot 'ordinary-stop-ran.txt'
        $probeScript = Join-Path $script:runtimeRoot 'ordinary-stop-probe.ps1'
        Set-Content -LiteralPath $probeScript -Value (
            "Set-Content -LiteralPath '$($markerPath.Replace("'", "''"))' -Value ran"
        )
        Compile-VmAutostopService -SourcePath (Join-Path $sourceRoot 'VmAutostopService.cs') `
            -OutputPath $executable

        $output = @(& $executable --console-ordinary-stop $probeScript 2>&1)

        $LASTEXITCODE | Should Be 0
        $output | Should Be @('SERVICE_STOPPED')
        Test-Path -LiteralPath $markerPath | Should Be $false
    }
}
