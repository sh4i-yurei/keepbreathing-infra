$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceRoot = Split-Path -Parent $here
$installScript = Join-Path $sourceRoot 'install.ps1'
. $installScript -FunctionsOnly -DestinationRoot 'C:\ProgramData\keepbreathing\vm-autostart'

function New-TestCredential {
    $securePassword = ConvertTo-SecureString 'test-only-password' -AsPlainText -Force
    New-Object Management.Automation.PSCredential('DELL', $securePassword)
}

Describe 'VM autostart installer' {
    BeforeEach {
        $script:destinationRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $script:state = @{
            Task = $null
            Service = $null
            Mutations = 0
            Prompts = 0
            TaskPasswords = @()
            ServicePasswords = @()
            Compiles = 0
            ServiceRunning = $false
            ServiceStops = 0
            RegistrationOrder = @()
        }
        $state = $script:state
        $credential = New-TestCredential
        $prompt = {
            param($UserName, $Message)
            $state.Prompts++
            $credential
        }.GetNewClosure()
        $getTask = { param($Name) $state.Task }.GetNewClosure()
        $registerTask = {
            param($Spec, $Password)
            $state.Task = $Spec.Fingerprint
            $state.TaskPasswords += $Password
            $state.RegistrationOrder += 'task'
            $state.Mutations++
        }.GetNewClosure()
        $compileService = {
            param($SourcePath, $OutputPath)
            Set-Content -LiteralPath $OutputPath -Value 'fake service executable'
            $state.Compiles++
            $state.Mutations++
        }.GetNewClosure()
        $getService = { param($Spec) $state.Service }.GetNewClosure()
        $registerService = {
            param($Spec, $Password)
            $state.Service = $Spec.Fingerprint
            $state.ServicePasswords += $Password
            $state.RegistrationOrder += 'service'
            $state.Mutations++
        }.GetNewClosure()
        $ensureServiceStarted = {
            param($Spec)
            $state.RegistrationOrder += 'start'
            if ($state.ServiceRunning) { return $false }
            $state.ServiceRunning = $true
            $state.Mutations++
            $true
        }.GetNewClosure()
        $stopService = {
            param($Spec)
            if (-not $state.ServiceRunning) { return $false }
            $state.ServiceRunning = $false
            $state.ServiceStops++
            $state.RegistrationOrder += 'stop'
            $state.Mutations++
            $true
        }.GetNewClosure()
        $ensureTree = {
            param($Root, $LogDirectory, $FileNames)
            $changed = @()
            foreach ($directory in @($Root, $LogDirectory)) {
                if (-not (Test-Path -LiteralPath $directory)) {
                    New-Item -ItemType Directory -Path $directory -Force | Out-Null
                    $changed += "directory $directory"
                    $state.Mutations++
                }
            }
            $changed
        }.GetNewClosure()
        $script:parameters = @{
            DestinationRoot          = $script:destinationRoot
            AdministratorCheck       = { $true }
            CredentialPromptAction   = $prompt
            GetTaskFingerprintAction = $getTask
            RegisterTaskAction       = $registerTask
            CompileServiceAction     = $compileService
            GetServiceFingerprintAction = $getService
            RegisterServiceAction    = $registerService
            StopServiceAction        = $stopService
            EnsureServiceStartedAction = $ensureServiceStarted
            EnsureInstallTreeAction  = $ensureTree
        }
    }

    It 'installs the runtime files, service binary, service and startup task definitions' {
        $output = @(& $installScript @parameters)

        foreach ($fileName in @(
                'config.psd1',
                'VmAutostart.psm1',
                'EntryPoint.Common.ps1',
                'startup.ps1',
                'stop.ps1',
                'VmAutostopService.cs',
                'VmAutostopService.exe',
                'VmAutostopService.source.sha256')) {
            Test-Path -LiteralPath (Join-Path $script:destinationRoot $fileName) | Should Be $true
        }
        $script:state.Task | Should Match '\|startup\|true\|true\|true\|true\|true\|0$'
        $script:state.Service | Should Match '^vm autostop\|dell\|2\|.* --service\|900000$'
        $script:state.Prompts | Should Be 1
        $script:state.Compiles | Should Be 1
        $script:state.TaskPasswords.Count | Should Be 1
        $script:state.ServicePasswords.Count | Should Be 1
        $script:state.TaskPasswords[0] | Should Be 'test-only-password'
        $script:state.ServicePasswords[0] | Should Be 'test-only-password'
        ($script:state.RegistrationOrder -join ',') | Should Be 'task,service,start'
        ($output -join "`n") | Should Match 'Changed: service VM autostop'
        ($output -join "`n") | Should Match 'Changed: service start VM autostop'
        ($output -join "`n") | Should Match 'Changed: task VM autostart - start'
    }

    It 'changes nothing and does not prompt on a normal second run' {
        & $installScript @parameters | Out-Null
        $mutationCount = $script:state.Mutations
        $promptCount = $script:state.Prompts

        $secondOutput = @(& $installScript @parameters)

        $script:state.Mutations | Should Be $mutationCount
        $script:state.Prompts | Should Be $promptCount
        $secondOutput | Should Be @('No changes required.')
    }

    It 'refreshes both stored passwords when a credential is supplied explicitly' {
        & $installScript @parameters | Out-Null
        $script:state.TaskPasswords = @()
        $script:state.ServicePasswords = @()

        $output = @(& $installScript @parameters -Credential (New-TestCredential))

        $script:state.TaskPasswords.Count | Should Be 1
        $script:state.ServicePasswords.Count | Should Be 1
        ($output -join "`n") | Should Match 'Changed: service VM autostop'
        ($output -join "`n") | Should Match 'Changed: task VM autostart - start'
    }

    It 'retries compilation after a failed build instead of trusting a stale executable' {
        & $installScript @parameters | Out-Null
        $stampPath = Join-Path $script:destinationRoot 'VmAutostopService.source.sha256'
        Set-Content -LiteralPath $stampPath -Value 'outdated'
        $script:parameters.CompileServiceAction = { throw 'fake compiler failure' }

        { & $installScript @parameters } | Should Throw
        (Get-Content -LiteralPath $stampPath -Raw).Trim() | Should Be 'outdated'

        $state = $script:state
        $script:parameters.CompileServiceAction = {
            param($SourcePath, $OutputPath)
            Set-Content -LiteralPath $OutputPath -Value 'rebuilt service executable'
            $state.Compiles++
            $state.Mutations++
        }.GetNewClosure()
        $output = @(& $installScript @parameters)

        (Get-Content -LiteralPath $stampPath -Raw).Trim() | Should Not Be 'outdated'
        ($output -join "`n") | Should Match 'Changed: service binary VmAutostopService.exe'
    }

    It 'stops a running service before replacing its executable and starts it again' {
        & $installScript @parameters | Out-Null
        $script:state.RegistrationOrder = @()
        $stampPath = Join-Path $script:destinationRoot 'VmAutostopService.source.sha256'
        Set-Content -LiteralPath $stampPath -Value 'outdated'

        $output = @(& $installScript @parameters)

        $script:state.ServiceStops | Should Be 1
        $script:state.ServiceRunning | Should Be $true
        ($script:state.RegistrationOrder -join ',') | Should Be 'stop,start'
        ($output -join "`n") | Should Match 'Changed: service stop VM autostop'
        ($output -join "`n") | Should Match 'Changed: service binary VmAutostopService.exe'
        ($output -join "`n") | Should Match 'Changed: service start VM autostop'
    }

    It 'refuses to change anything without elevation' {
        $script:parameters.AdministratorCheck = { $false }
        { & $installScript @parameters } | Should Throw
        $script:state.Mutations | Should Be 0
    }
}

Describe 'VM autostart installer production adapters' {
    It 'matches the inverse battery properties returned for an installed startup task' {
        $spec = New-TaskSpec -Name 'VM autostart - start' -ScriptName 'startup.ps1'
        $installedTask = [pscustomobject]@{
            Actions = @([pscustomobject]@{
                    Execute          = $spec.Execute
                    Arguments        = $spec.Arguments
                    WorkingDirectory = $spec.WorkingDirectory
                })
            Triggers = @([pscustomobject]@{
                    Enabled  = $true
                    CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskBootTrigger' }
                })
            Principal = [pscustomobject]@{
                UserId    = 'WSOPTICON1\DELL'
                RunLevel  = 'Highest'
                LogonType = 'Password'
            }
            Settings = [pscustomobject]@{
                Enabled                       = $true
                StartWhenAvailable            = $true
                DisallowStartIfOnBatteries    = $false
                StopIfGoingOnBatteries        = $false
                ExecutionTimeLimit            = 'PT0S'
            }
        }

        $getTaskAction = ({ param($Name) $installedTask }).GetNewClosure()
        $fingerprint = Get-InstalledTaskFingerprint -Name $spec.Name `
            -GetTaskAction $getTaskAction

        $fingerprint | Should Be $spec.Fingerprint
    }

    It 'builds the startup task with password logon and highest privileges' {
        $spec = New-TaskSpec -Name 'VM autostart - start' -ScriptName 'startup.ps1'
        $state = @{}
        Register-VmAutostartTask -Spec $spec -Password 'test-only' `
            -NewActionAction { param($CurrentSpec) "action:$($CurrentSpec.ScriptName)" } `
            -NewTriggerAction { 'trigger:startup' } `
            -NewSettingsAction { 'settings' } `
            -RegisterAction {
                param($CurrentSpec, $Action, $Trigger, $Settings, $Password)
                $state.Spec = $CurrentSpec; $state.Trigger = $Trigger; $state.Password = $Password
            }

        $state.Spec.User | Should Be 'DELL'
        $state.Spec.RunLevel | Should Be 'Highest'
        $state.Spec.LogonType | Should Be 'Password'
        $state.Trigger | Should Be 'trigger:startup'
        $state.Password | Should Be 'test-only'
    }

    It 'defines the automatic DELL service and its 900000 ms preshutdown timeout' {
        $spec = New-ServiceSpec

        $spec.Name | Should Be 'VM autostop'
        $spec.User | Should Be '.\DELL'
        $spec.StartType | Should Be 2
        $spec.PreshutdownTimeoutMilliseconds | Should Be 900000
        $spec.BinaryPath | Should Match '^".*VmAutostopService\.exe" --service$'
        $spec.BinaryPath | Should Not Match 'test-only-password'
        $spec.Fingerprint | Should Match '\|dell\|2\|.*\|900000$'
    }

    It 'uses the documented preshutdown service configuration API' {
        $source = Get-Content -LiteralPath (Join-Path $sourceRoot 'VmAutostopService.cs') -Raw

        $source | Should Match 'SERVICE_ACCEPT_PRESHUTDOWN|ServiceAcceptPreshutdown'
        $source | Should Match 'ChangeServiceConfig2'
        $source | Should Match 'ServiceConfigPreshutdownInfo = 7'
        $source | Should Match 'PreshutdownTimeout'
        $source | Should Match 'SeServiceLogonRight'
        $source | Should Match 'EnsureStarted'
    }

    It 'validates install paths and separates runtime and log permissions' {
        $root = $sourceRoot
        $logDirectory = Join-Path $root 'logs'
        $state = @{ Validated = @(); Secured = @() }
        $validate = { param($Path) $state.Validated += $Path }.GetNewClosure()
        $secure = {
            param($Path, $AllowModify)
            $state.Secured += "$Path|$AllowModify"
            $true
        }.GetNewClosure()

        $changes = @(Protect-InstallTree -Root $root -LogDirectory $logDirectory `
                -FileNames @('startup.ps1') -PathExistsAction { $true } `
                -ValidatePathAction $validate -CreateDirectoryAction {} -SecurePathAction $secure)

        ($state.Validated -contains $root) | Should Be $true
        ($state.Validated -contains $logDirectory) | Should Be $true
        ($state.Secured -contains "$root|False") | Should Be $true
        ($state.Secured -contains "$logDirectory|True") | Should Be $true
        ($changes -join "`n") | Should Match 'ACL'
    }
}
