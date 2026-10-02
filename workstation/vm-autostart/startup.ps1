[CmdletBinding()]
param(
    [scriptblock] $StartAction,

    [string] $LogDirectory
)

. (Join-Path $PSScriptRoot 'EntryPoint.Common.ps1')
if (-not $LogDirectory) { $LogDirectory = Join-Path $PSScriptRoot 'logs' }

try {
    if (-not $StartAction) {
        $config = Import-VmAutostartRuntime -SourceRoot $PSScriptRoot
        $StartAction = { Start-ManagedVms -Config $config }
    }
    Write-VmAutostartLog -LogDirectory $LogDirectory -EntryPoint 'startup' -Message 'Starting managed VMs.'
    $result = @(& $StartAction)
    foreach ($vmResult in $result) {
        Write-VmAutostartLog -LogDirectory $LogDirectory -EntryPoint 'startup' -Message (
            "VM '$($vmResult.VmName)' start result: $($vmResult.Action) after $($vmResult.Attempts) attempt(s)."
        )
    }
    Write-VmAutostartLog -LogDirectory $LogDirectory -EntryPoint 'startup' -Message ("Processed {0} managed VMs." -f $result.Count)
    $result
}
catch {
    Write-VmAutostartLog -LogDirectory $LogDirectory -EntryPoint 'startup' -Message ("Failed: {0}" -f $_.Exception.Message)
    throw
}
