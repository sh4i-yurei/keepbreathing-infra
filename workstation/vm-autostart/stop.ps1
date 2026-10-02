[CmdletBinding()]
param(
    [scriptblock] $StopAction,
    [string] $LogDirectory
)

. (Join-Path $PSScriptRoot 'EntryPoint.Common.ps1')
if (-not $LogDirectory) { $LogDirectory = Join-Path $PSScriptRoot 'logs' }

try {
    if (-not $StopAction) {
        $config = Import-VmAutostartRuntime -SourceRoot $PSScriptRoot
        $StopAction = { Stop-ManagedVms -Config $config }
    }

    Write-VmAutostartLog -LogDirectory $LogDirectory -EntryPoint 'stop' -Message 'Stopping managed VMs.'
    $results = @(& $StopAction)
    foreach ($result in $results) {
        $prefix = if ($result.Action -eq 'Failed') {
            'Failure: '
        }
        elseif ($result.Action -eq 'SavedState' -or $result.Error) {
            'Warning: '
        }
        else { '' }
        $detail = if ($result.Error) { " Detail: $($result.Error)" } else { '' }
        Write-VmAutostartLog -LogDirectory $LogDirectory -EntryPoint 'stop' -Message (
            "${prefix}VM '$($result.VmName)' stop result: $($result.Action) after $($result.ElapsedSeconds) seconds.${detail}"
        )
    }
    Write-VmAutostartLog -LogDirectory $LogDirectory -EntryPoint 'stop' -Message (
        'Stop completed for {0} managed VMs.' -f $results.Count
    )
    $failedVms = @($results | Where-Object { $_.Action -eq 'Failed' })
    if ($failedVms.Count -gt 0) {
        throw 'Stop failed for: {0}.' -f (($failedVms | ForEach-Object { $_.VmName }) -join ', ')
    }
    $results
}
catch {
    Write-VmAutostartLog -LogDirectory $LogDirectory -EntryPoint 'stop' -Message ("Failed: {0}" -f $_.Exception.Message)
    throw
}
