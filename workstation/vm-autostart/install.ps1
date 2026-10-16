[CmdletBinding()]
param(
    [pscredential] $Credential,
    [switch] $FunctionsOnly,
    [string] $DestinationRoot = 'C:\ProgramData\keepbreathing\vm-autostart',
    [scriptblock] $AdministratorCheck,
    [scriptblock] $CredentialPromptAction,
    [scriptblock] $GetTaskFingerprintAction,
    [scriptblock] $RegisterTaskAction,
    [scriptblock] $CompileServiceAction,
    [scriptblock] $GetServiceFingerprintAction,
    [scriptblock] $RegisterServiceAction,
    [scriptblock] $StopServiceAction,
    [scriptblock] $EnsureServiceStartedAction,
    [scriptblock] $EnsureInstallTreeAction
)

$ErrorActionPreference = 'Stop'
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$sourceFiles = @(
    'config.psd1',
    'VmAutostart.psm1',
    'EntryPoint.Common.ps1',
    'startup.ps1',
    'stop.ps1',
    'VmAutostopService.cs'
)
$serviceExecutableName = 'VmAutostopService.exe'
$serviceSourceHashName = 'VmAutostopService.source.sha256'

function ConvertTo-BoolFingerprint {
    param([object] $Value)
    ([bool] $Value).ToString().ToLowerInvariant()
}

function ConvertTo-DurationTicks {
    param([object] $Value)
    if ($Value -is [timespan]) { return ([timespan] $Value).Ticks }
    try { [Xml.XmlConvert]::ToTimeSpan([string] $Value).Ticks }
    catch { -1 }
}

function New-TaskSpec {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $ScriptName
    )

    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f
        (Join-Path $DestinationRoot $ScriptName)
    $fingerprint = ('{0}|DELL|Highest|Password|{1}|{2}|{3}|Startup|true|true|true|true|true|0' -f
        $Name, $powershellPath, $arguments, $DestinationRoot).ToLowerInvariant()

    [pscustomobject]@{
        Name             = $Name
        ScriptName       = $ScriptName
        Execute          = $powershellPath
        Arguments        = $arguments
        WorkingDirectory = $DestinationRoot
        User             = 'DELL'
        RunLevel         = 'Highest'
        LogonType        = 'Password'
        Fingerprint      = $fingerprint
    }
}

function New-ServiceSpec {
    $executablePath = Join-Path $DestinationRoot $serviceExecutableName
    $binaryPath = '"{0}" --service' -f $executablePath
    $fingerprint = ('VM autostop|DELL|2|{0}|900000' -f $binaryPath).ToLowerInvariant()

    [pscustomobject]@{
        Name                          = 'VM autostop'
        DisplayName                   = 'VM autostop'
        ExecutablePath                = $executablePath
        BinaryPath                    = $binaryPath
        User                          = '.\DELL'
        StartType                     = 2
        PreshutdownTimeoutMilliseconds = 900000
        Fingerprint                   = $fingerprint
    }
}

function Compile-VmAutostopService {
    param(
        [Parameter(Mandatory = $true)][string] $SourcePath,
        [Parameter(Mandatory = $true)][string] $OutputPath,
        [string] $CompilerPath = (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe')
    )

    if (-not (Test-Path -LiteralPath $CompilerPath -PathType Leaf)) {
        throw "The built-in .NET Framework compiler was not found at '$CompilerPath'."
    }
    $compilerOutput = @(& $CompilerPath /nologo /target:exe /platform:anycpu `
            "/out:$OutputPath" $SourcePath 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The VM autostop service did not compile (exit $LASTEXITCODE): $($compilerOutput -join [Environment]::NewLine)"
    }
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        throw "The compiler returned success without creating '$OutputPath'."
    }
}

function Get-VmAutostopServiceConfigurationType {
    param([Parameter(Mandatory = $true)][string] $ExecutablePath)

    if ($script:vmAutostopServiceConfigurationType) {
        return $script:vmAutostopServiceConfigurationType
    }
    $assembly = [Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($ExecutablePath))
    $script:vmAutostopServiceConfigurationType = $assembly.GetType(
        'VmAutostopServiceConfiguration', $false, $false)
    if (-not $script:vmAutostopServiceConfigurationType) {
        throw "The service configuration type was not found in '$ExecutablePath'."
    }
    $script:vmAutostopServiceConfigurationType
}

function Get-InstalledServiceFingerprint {
    param([Parameter(Mandatory = $true)][object] $Spec)

    $type = Get-VmAutostopServiceConfigurationType -ExecutablePath $Spec.ExecutablePath
    $type.GetMethod('GetFingerprint').Invoke($null, @($Spec.Name))
}

function Register-VmAutostopService {
    param(
        [Parameter(Mandatory = $true)][object] $Spec,
        [Parameter(Mandatory = $true)][string] $Password
    )

    $type = Get-VmAutostopServiceConfigurationType -ExecutablePath $Spec.ExecutablePath
    $arguments = @(
        $Spec.Name,
        $Spec.DisplayName,
        $Spec.BinaryPath,
        $Spec.User,
        $Password,
        [uint32] $Spec.PreshutdownTimeoutMilliseconds
    )
    $null = $type.GetMethod('Configure').Invoke($null, $arguments)
}

function Ensure-VmAutostopServiceStarted {
    param([Parameter(Mandatory = $true)][object] $Spec)

    $type = Get-VmAutostopServiceConfigurationType -ExecutablePath $Spec.ExecutablePath
    [bool] $type.GetMethod('EnsureStarted').Invoke($null, @($Spec.Name))
}

function Get-InstalledTaskFingerprint {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [scriptblock] $GetTaskAction
    )

    if (-not $GetTaskAction) {
        $GetTaskAction = { param($TaskName) Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue }
    }
    $task = & $GetTaskAction $Name
    if (-not $task -or $task.Actions.Count -ne 1 -or $task.Triggers.Count -ne 1) { return $null }
    if ([string] $task.Triggers[0].CimClass.CimClassName -ne 'MSFT_TaskBootTrigger') { return $null }

    $userId = [string] $task.Principal.UserId
    if ($userId -match '(^|\\)DELL$') { $userId = 'DELL' }
    $action = $task.Actions[0]
    ('{0}|{1}|{2}|{3}|{4}|{5}|{6}|Startup|{7}|{8}|{9}|{10}|{11}|{12}' -f
        $Name,
        $userId,
        [string] $task.Principal.RunLevel,
        [string] $task.Principal.LogonType,
        [string] $action.Execute,
        [string] $action.Arguments,
        [string] $action.WorkingDirectory,
        (ConvertTo-BoolFingerprint $task.Settings.Enabled),
        (ConvertTo-BoolFingerprint $task.Triggers[0].Enabled),
        (ConvertTo-BoolFingerprint $task.Settings.StartWhenAvailable),
        (ConvertTo-BoolFingerprint (-not [bool] $task.Settings.DisallowStartIfOnBatteries)),
        (ConvertTo-BoolFingerprint (-not [bool] $task.Settings.StopIfGoingOnBatteries)),
        (ConvertTo-DurationTicks $task.Settings.ExecutionTimeLimit)).ToLowerInvariant()
}

function Register-VmAutostartTask {
    param(
        [Parameter(Mandatory = $true)][object] $Spec,
        [Parameter(Mandatory = $true)][string] $Password,
        [scriptblock] $NewActionAction,
        [scriptblock] $NewTriggerAction,
        [scriptblock] $NewSettingsAction,
        [scriptblock] $RegisterAction
    )

    if (-not $NewActionAction) {
        $NewActionAction = {
            param($CurrentSpec)
            New-ScheduledTaskAction -Execute $CurrentSpec.Execute -Argument $CurrentSpec.Arguments `
                -WorkingDirectory $CurrentSpec.WorkingDirectory
        }
    }
    if (-not $NewTriggerAction) { $NewTriggerAction = { New-ScheduledTaskTrigger -AtStartup } }
    if (-not $NewSettingsAction) {
        $NewSettingsAction = {
            New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([timespan]::Zero)
        }
    }
    if (-not $RegisterAction) {
        $RegisterAction = {
            param($CurrentSpec, $CurrentAction, $CurrentTrigger, $CurrentSettings, $CurrentPassword)
            Register-ScheduledTask -TaskName $CurrentSpec.Name -Action $CurrentAction `
                -Trigger $CurrentTrigger -Settings $CurrentSettings -User $CurrentSpec.User `
                -Password $CurrentPassword -RunLevel $CurrentSpec.RunLevel `
                -Description 'keepbreathing VM autostart' -Force -ErrorAction Stop | Out-Null
        }
    }

    $action = & $NewActionAction $Spec
    $trigger = & $NewTriggerAction
    $settings = & $NewSettingsAction
    & $RegisterAction $Spec $action $trigger $settings $Password
}

function Assert-PathComponentsNotReparse {
    param([Parameter(Mandatory = $true)][string] $Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    $current = $root
    foreach ($part in $fullPath.Substring($root.Length).Split(@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to use reparse point '$current' in the privileged install path."
            }
        }
    }
}

function Test-AccessControlEquivalent {
    param(
        [Parameter(Mandatory = $true)][object] $Current,
        [Parameter(Mandatory = $true)][object] $Desired
    )

    if ($Current.AreAccessRulesProtected -ne $Desired.AreAccessRulesProtected) { return $false }
    $identityType = [Security.Principal.SecurityIdentifier]
    if ($Current.GetOwner($identityType).Value -ne $Desired.GetOwner($identityType).Value) {
        return $false
    }
    $getRuleFingerprint = {
        param($Acl)
        @($Acl.GetAccessRules($true, $true, $identityType) | ForEach-Object {
                '{0}|{1}|{2}|{3}|{4}|{5}' -f
                    $_.IdentityReference.Value,
                    [int64] $_.FileSystemRights,
                    $_.AccessControlType,
                    $_.InheritanceFlags,
                    $_.PropagationFlags,
                    $_.IsInherited
            } | Sort-Object) -join "`n"
    }
    (& $getRuleFingerprint $Current) -eq (& $getRuleFingerprint $Desired)
}

function Set-SecureInstallAcl {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [switch] $AllowModify
    )

    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to secure reparse point '$Path'."
    }
    $isDirectory = [bool] $item.PSIsContainer
    if ($isDirectory) {
        $desired = New-Object Security.AccessControl.DirectorySecurity
        $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    }
    else {
        $desired = New-Object Security.AccessControl.FileSecurity
        $inheritance = [Security.AccessControl.InheritanceFlags]::None
    }
    $desired.SetAccessRuleProtection($true, $false)
    $desired.SetOwner((New-Object Security.Principal.NTAccount('BUILTIN', 'Administrators')))
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $desired.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                'NT AUTHORITY\SYSTEM', [Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance, $propagation, $allow)))
    $desired.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                'BUILTIN\Administrators', [Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance, $propagation, $allow)))
    $dellRights = if ($AllowModify) {
        [Security.AccessControl.FileSystemRights]::Modify
    }
    else {
        [Security.AccessControl.FileSystemRights]::ReadAndExecute
    }
    $desired.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                "$env:COMPUTERNAME\DELL", $dellRights, $inheritance, $propagation, $allow)))

    $current = Get-Acl -LiteralPath $Path
    if (Test-AccessControlEquivalent -Current $current -Desired $desired) {
        return $false
    }
    Set-Acl -LiteralPath $Path -AclObject $desired
    $true
}

function Protect-InstallTree {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $LogDirectory,
        [Parameter(Mandatory = $true)][string[]] $FileNames,
        [scriptblock] $PathExistsAction,
        [scriptblock] $ValidatePathAction,
        [scriptblock] $CreateDirectoryAction,
        [scriptblock] $SecurePathAction
    )

    if (-not $PathExistsAction) { $PathExistsAction = { param($Path) Test-Path -LiteralPath $Path } }
    if (-not $ValidatePathAction) { $ValidatePathAction = { param($Path) Assert-PathComponentsNotReparse -Path $Path } }
    if (-not $CreateDirectoryAction) {
        $CreateDirectoryAction = { param($Path) New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    }
    if (-not $SecurePathAction) {
        $SecurePathAction = { param($Path, $AllowModify) Set-SecureInstallAcl -Path $Path -AllowModify:$AllowModify }
    }

    $changed = New-Object System.Collections.Generic.List[string]
    foreach ($directory in @($Root, $LogDirectory)) {
        & $ValidatePathAction $directory
        if (-not (& $PathExistsAction $directory)) {
            & $CreateDirectoryAction $directory
            $changed.Add("directory $directory")
        }
    }
    if (& $SecurePathAction $Root $false) { $changed.Add("ACL $Root") }
    if (& $SecurePathAction $LogDirectory $true) { $changed.Add("ACL $LogDirectory") }
    foreach ($fileName in $FileNames) {
        $path = Join-Path $Root $fileName
        & $ValidatePathAction $path
        if ((& $PathExistsAction $path) -and (& $SecurePathAction $path $false)) {
            $changed.Add("ACL $path")
        }
    }
    @($changed)
}

function Test-FileContentEqual {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination
    )
    if (-not (Test-Path -LiteralPath $Destination)) { return $false }
    (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -eq
        (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
}

if ($FunctionsOnly) { return }

if (-not $AdministratorCheck) {
    $AdministratorCheck = {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
}
if (-not $CredentialPromptAction) {
    $CredentialPromptAction = {
        param($UserName, $Message)
        Get-Credential -UserName $UserName -Message $Message
    }
}
if (-not $GetTaskFingerprintAction) {
    $GetTaskFingerprintAction = { param($Name) Get-InstalledTaskFingerprint -Name $Name }
}
if (-not $RegisterTaskAction) {
    $RegisterTaskAction = { param($Spec, $Password) Register-VmAutostartTask -Spec $Spec -Password $Password }
}
if (-not $CompileServiceAction) {
    $CompileServiceAction = {
        param($SourcePath, $OutputPath)
        Compile-VmAutostopService -SourcePath $SourcePath -OutputPath $OutputPath
    }
}
if (-not $GetServiceFingerprintAction) {
    $GetServiceFingerprintAction = { param($Spec) Get-InstalledServiceFingerprint -Spec $Spec }
}
if (-not $RegisterServiceAction) {
    $RegisterServiceAction = {
        param($Spec, $Password)
        Register-VmAutostopService -Spec $Spec -Password $Password
    }
}
if (-not $StopServiceAction) {
    $StopServiceAction = {
        param($Spec)
        $service = Get-Service -Name $Spec.Name -ErrorAction SilentlyContinue
        if (-not $service -or $service.Status -eq 'Stopped') { return $false }
        Stop-Service -Name $Spec.Name -Force -ErrorAction Stop
        $service.WaitForStatus('Stopped', [timespan]::FromSeconds(15))
        $true
    }
}
if (-not $EnsureServiceStartedAction) {
    $EnsureServiceStartedAction = {
        param($Spec)
        Ensure-VmAutostopServiceStarted -Spec $Spec
    }
}
if (-not $EnsureInstallTreeAction) {
    $EnsureInstallTreeAction = {
        param($Root, $LogDirectory, $FileNames)
        Protect-InstallTree -Root $Root -LogDirectory $LogDirectory -FileNames $FileNames
    }
}

if (-not (& $AdministratorCheck)) { throw 'Run install.ps1 from an elevated Windows PowerShell session.' }

$changes = New-Object System.Collections.Generic.List[string]
$logDirectory = Join-Path $DestinationRoot 'logs'
$serviceSpec = New-ServiceSpec
$protectedFiles = @($sourceFiles) + @($serviceExecutableName, $serviceSourceHashName)
@(& $EnsureInstallTreeAction $DestinationRoot $logDirectory $protectedFiles) | ForEach-Object {
    $changes.Add([string] $_)
}
foreach ($fileName in $sourceFiles) {
    $source = Join-Path $PSScriptRoot $fileName
    $destination = Join-Path $DestinationRoot $fileName
    if (-not (Test-FileContentEqual -Source $source -Destination $destination)) {
        Copy-Item -LiteralPath $source -Destination $destination -Force
        $changes.Add("file $fileName")
    }
}
$serviceSourcePath = Join-Path $DestinationRoot 'VmAutostopService.cs'
$serviceExecutablePath = Join-Path $DestinationRoot $serviceExecutableName
$serviceSourceHashPath = Join-Path $DestinationRoot $serviceSourceHashName
$serviceSourceHash = (Get-FileHash -LiteralPath $serviceSourcePath -Algorithm SHA256).Hash
$installedSourceHash = if (Test-Path -LiteralPath $serviceSourceHashPath -PathType Leaf) {
    (Get-Content -LiteralPath $serviceSourceHashPath -Raw).Trim()
}
else { $null }
if ($serviceSourceHash -ne $installedSourceHash -or
    -not (Test-Path -LiteralPath $serviceExecutablePath -PathType Leaf)) {
    $candidatePath = Join-Path $DestinationRoot ("VmAutostopService.{0}.exe" -f [guid]::NewGuid())
    $serviceStoppedForBinaryUpdate = $false
    try {
        & $CompileServiceAction $serviceSourcePath $candidatePath
        $serviceStoppedForBinaryUpdate = [bool] (& $StopServiceAction $serviceSpec)
        if ($serviceStoppedForBinaryUpdate) {
            $changes.Add("service stop $($serviceSpec.Name)")
        }
        try {
            Move-Item -LiteralPath $candidatePath -Destination $serviceExecutablePath -Force
        }
        catch {
            if ($serviceStoppedForBinaryUpdate) {
                $null = & $EnsureServiceStartedAction $serviceSpec
            }
            throw "Could not replace '$serviceExecutablePath': $($_.Exception.Message)"
        }
        Set-Content -LiteralPath $serviceSourceHashPath -Value $serviceSourceHash -Encoding ASCII
        $changes.Add("service binary $serviceExecutableName")
    }
    finally {
        if (Test-Path -LiteralPath $candidatePath) {
            Remove-Item -LiteralPath $candidatePath -Force
        }
    }
}
@(& $EnsureInstallTreeAction $DestinationRoot $logDirectory $protectedFiles) | ForEach-Object {
    if (-not $changes.Contains([string] $_)) { $changes.Add([string] $_) }
}

$taskSpec = New-TaskSpec -Name 'VM autostart - start' -ScriptName 'startup.ps1'
$credentialWasProvided = $null -ne $Credential
$taskNeedsChange = $credentialWasProvided -or
    ((& $GetTaskFingerprintAction $taskSpec.Name) -ne $taskSpec.Fingerprint)
$serviceNeedsChange = $credentialWasProvided -or
    ((& $GetServiceFingerprintAction $serviceSpec) -ne $serviceSpec.Fingerprint)
if (($taskNeedsChange -or $serviceNeedsChange) -and -not $Credential) {
    $Credential = & $CredentialPromptAction 'DELL' `
        'Enter the DELL password. Windows stores it for VM autostart.'
}
if (($taskNeedsChange -or $serviceNeedsChange) -and -not $Credential) {
    throw 'A DELL credential is required to register VM autostart.'
}

$plainPassword = $null
try {
    if ($taskNeedsChange) {
        $plainPassword = $Credential.GetNetworkCredential().Password
        & $RegisterTaskAction $taskSpec $plainPassword
        $changes.Add("task $($taskSpec.Name)")
    }
    if ($serviceNeedsChange) {
        if ($null -eq $plainPassword) { $plainPassword = $Credential.GetNetworkCredential().Password }
        & $RegisterServiceAction $serviceSpec $plainPassword
        $changes.Add("service $($serviceSpec.Name)")
    }
}
finally { $plainPassword = $null }

if (& $EnsureServiceStartedAction $serviceSpec) {
    $changes.Add("service start $($serviceSpec.Name)")
}

if ($changes.Count -eq 0) { Write-Output 'No changes required.' }
else { $changes | ForEach-Object { Write-Output "Changed: $_" } }
