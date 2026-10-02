param(
    [Parameter(Mandatory = $true, Position = 0)][string] $Command,
    [Parameter(Mandatory = $true, Position = 1)][string] $VmName,
    [Parameter(ValueFromRemainingArguments = $true)][string[]] $RemainingArguments
)

$ErrorActionPreference = 'Stop'
$root = $env:VM_AUTOSTART_FAKE_DIR
if (-not $root) { throw 'VM_AUTOSTART_FAKE_DIR is not set.' }

$scenario = $env:VM_AUTOSTART_SCENARIO
$arguments = @($Command, $VmName) + $RemainingArguments
Add-Content -LiteralPath (Join-Path $root "$VmName.log") -Value ($arguments -join ' ')

function Get-NextCount {
    param([string] $Name)
    $path = Join-Path $root "$VmName.$Name.count"
    $count = 1
    if (Test-Path -LiteralPath $path) { $count += [int](Get-Content -LiteralPath $path -Raw) }
    Set-Content -LiteralPath $path -Value $count
    $count
}

function Wait-ForParallelPeers {
    param([string] $Operation)
    New-Item -ItemType File -Path (Join-Path $root "$Operation-$VmName.ready") -Force | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (@(Get-ChildItem -LiteralPath $root -Filter "$Operation-*.ready").Count -lt 3) {
        if ([DateTime]::UtcNow -ge $deadline) {
            [Console]::Error.WriteLine('VBoxManage fake timed out waiting for parallel commands.')
            exit 2
        }
        Start-Sleep -Milliseconds 50
    }
}

switch ($Command) {
    'showvminfo' {
        if ($scenario -eq 'hung-status') { Start-Sleep -Seconds 5 }
        if ($scenario -eq 'repeated-status-error') {
            [Console]::Error.WriteLine("Fake repeated status failure for '$VmName'.")
            exit 1
        }
        if ($scenario -eq 'slow-status-start') { Start-Sleep -Milliseconds 500 }
        if ($scenario -eq 'large-output') {
            1..256 | ForEach-Object { 'Property{0}="{1}"' -f $_, ('x' * 128) }
            'VMState="poweroff"'
            break
        }

        $stateCheck = Get-NextCount -Name 'state'
        $acpiMarker = Join-Path $root "$VmName.acpi"
        $resumeMarker = Join-Path $root "$VmName.resume"
        $startedMarker = Join-Path $root "$VmName.started"
        if (Test-Path -LiteralPath $startedMarker) { 'VMState="running"'; break }
        if ((Test-Path -LiteralPath $acpiMarker) -and $scenario -ne 'running-ignore-acpi') {
            'VMState="poweroff"'; break
        }

        switch ($scenario) {
            'state-poweroff' { 'VMState="poweroff"' }
            'state-saved' { 'VMState="saved"' }
            'state-aborted' { 'VMState="aborted"' }
            'state-paused' {
                if (Test-Path -LiteralPath $resumeMarker) { 'VMState="running"' } else { 'VMState="paused"' }
            }
            'stop-unknown' { 'VMState="teleporting"' }
            'start-unknown' {
                if ($stateCheck -ge 3) { 'VMState="poweroff"' } else { 'VMState="teleporting"' }
            }
            'final-off' {
                if ($stateCheck -ge 2) { 'VMState="poweroff"' } else { 'VMState="teleporting"' }
            }
            'hung-save' { 'VMState="teleporting"' }
            'hung-start' { 'VMState="poweroff"' }
            'slow-status-start' { 'VMState="poweroff"' }
            'start-locked' { 'VMState="poweroff"' }
            'parallel-start' { 'VMState="poweroff"' }
            default { 'VMState="running"' }
        }
    }
    'controlvm' {
        switch ($RemainingArguments[0]) {
            'resume' {
                if ($scenario -eq 'hung-control') { Start-Sleep -Seconds 5 }
                New-Item -ItemType File -Path (Join-Path $root "$VmName.resume") -Force | Out-Null
            }
            'acpipowerbutton' {
                if ($scenario -eq 'parallel-stop') { Wait-ForParallelPeers -Operation 'stop' }
                if ($scenario -eq 'hung-control') { Start-Sleep -Seconds 5 }
                if ($scenario -eq 'one-control-failure' -and $VmName -eq 'hub') {
                    [Console]::Error.WriteLine("Fake ACPI failure for '$VmName'.")
                    exit 1
                }
                New-Item -ItemType File -Path (Join-Path $root "$VmName.acpi") -Force | Out-Null
            }
            'savestate' {
                if ($scenario -eq 'hung-save') { Start-Sleep -Seconds 5 }
                New-Item -ItemType File -Path (Join-Path $root "$VmName.saved") -Force | Out-Null
            }
        }
    }
    'startvm' {
        if ($scenario -eq 'parallel-start') { Wait-ForParallelPeers -Operation 'start' }
        if ($scenario -in @('hung-start', 'slow-status-start')) { Start-Sleep -Seconds 5 }

        $attempts = Get-NextCount -Name 'attempts'
        if ($scenario -eq 'start-locked' -and $VmName -eq 'hub' -and $attempts -le 2) {
            [Console]::Error.WriteLine("VBoxManage.exe: error: The machine '$VmName' is already locked by a session")
            exit 1
        }
        New-Item -ItemType File -Path (Join-Path $root "$VmName.started") -Force | Out-Null
    }
}
