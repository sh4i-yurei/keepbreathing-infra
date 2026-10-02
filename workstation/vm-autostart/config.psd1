@{
    ManagedVms                  = @('AlmaServ', 'VaultServ', 'hub')
    VBoxManagePath              = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
    StopTimeoutSeconds          = 120
    StartTimeoutSeconds         = 60
    RetryIntervalSeconds        = 5
    StatusCallTimeoutSeconds    = 30
    ControlCallTimeoutSeconds   = 30
    StartCallTimeoutSeconds     = 30
    SaveStateCallTimeoutSeconds = 600
}
