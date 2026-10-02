function Write-VmAutostartLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $LogDirectory,

        [Parameter(Mandatory = $true)]
        [string] $EntryPoint,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    $now = Get-Date
    $logPath = Join-Path $LogDirectory ($now.ToString('yyyy-MM-dd') + '.log')
    Add-Content -LiteralPath $logPath -Value ('{0:o} [{1}] {2}' -f $now, $EntryPoint, $Message)
}

function Import-VmAutostartRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourceRoot
    )

    Import-Module (Join-Path $SourceRoot 'VmAutostart.psm1') -Force
    Import-PowerShellDataFile -LiteralPath (Join-Path $SourceRoot 'config.psd1')
}
