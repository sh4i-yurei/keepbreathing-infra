using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Threading;

internal static class VmAutostopService
{
    private const string ServiceName = "VM autostop";
    private const uint ServiceWin32OwnProcess = 0x00000010;
    private const uint ServiceStopped = 0x00000001;
    private const uint ServiceStartPending = 0x00000002;
    private const uint ServiceStopPending = 0x00000003;
    private const uint ServiceRunning = 0x00000004;
    private const uint ServiceAcceptStop = 0x00000001;
    private const uint ServiceAcceptPreshutdown = 0x00000100;
    private const uint ServiceControlStop = 0x00000001;
    private const uint ServiceControlInterrogate = 0x00000004;
    private const uint ServiceControlPreshutdown = 0x0000000F;
    private const uint ErrorServiceSpecificError = 1066;
    private const int NoError = 0;

    private static readonly object StatusLock = new object();
    private static readonly ManualResetEvent StopFinished = new ManualResetEvent(false);
    private static readonly ServiceMainFunction ServiceMainDelegate = ServiceMain;
    private static readonly HandlerExFunction HandlerDelegate = HandlerEx;
    private static IntPtr statusHandle = IntPtr.Zero;
    private static ServiceStatus currentStatus;
    private static int stopStarted;
    private static uint checkpoint;

    public static int Main(string[] args)
    {
        if (args.Length > 0 && String.Equals(args[0], "--console-stop", StringComparison.OrdinalIgnoreCase))
        {
            string scriptPath = args.Length > 1 ? args[1] : GetStopScriptPath();
            return RunConsoleControl(ServiceControlPreshutdown, scriptPath);
        }
        if (args.Length > 0 && String.Equals(
            args[0], "--console-ordinary-stop", StringComparison.OrdinalIgnoreCase))
        {
            string scriptPath = args.Length > 1 ? args[1] : GetStopScriptPath();
            return RunConsoleControl(ServiceControlStop, scriptPath);
        }

        ServiceTableEntry[] dispatchTable = new ServiceTableEntry[2];
        dispatchTable[0].ServiceName = ServiceName;
        dispatchTable[0].ServiceMain = ServiceMainDelegate;
        dispatchTable[1].ServiceName = null;
        dispatchTable[1].ServiceMain = null;
        if (!StartServiceCtrlDispatcher(dispatchTable))
        {
            return Marshal.GetLastWin32Error();
        }
        return 0;
    }

    private static void ServiceMain(int argumentCount, IntPtr argumentVector)
    {
        statusHandle = RegisterServiceCtrlHandlerEx(ServiceName, HandlerDelegate, IntPtr.Zero);
        if (statusHandle == IntPtr.Zero)
        {
            return;
        }

        ReportStatus(ServiceStartPending, 0, 1, 3000, 0, 0);
        ReportStatus(ServiceRunning, ServiceAcceptStop | ServiceAcceptPreshutdown, 0, 0, 0, 0);
        StopFinished.WaitOne();
    }

    private static uint HandlerEx(uint control, uint eventType, IntPtr eventData, IntPtr context)
    {
        if (control == ServiceControlStop || control == ServiceControlPreshutdown)
        {
            if (ControlRunsStopScript(control))
            {
                BeginStop();
            }
            else
            {
                CompleteOrdinaryStop();
            }
            return NoError;
        }
        if (control == ServiceControlInterrogate)
        {
            lock (StatusLock)
            {
                SetServiceStatus(statusHandle, ref currentStatus);
            }
        }
        return NoError;
    }

    private static bool ControlRunsStopScript(uint control)
    {
        return control == ServiceControlPreshutdown;
    }

    private static int RunConsoleControl(uint control, string scriptPath)
    {
        if (!ControlRunsStopScript(control))
        {
            Console.WriteLine("SERVICE_STOPPED");
            return 0;
        }

        Console.WriteLine("SERVICE_STOP_PENDING");
        int exitCode;
        try
        {
            exitCode = RunStopScript(
                scriptPath,
                delegate { Console.WriteLine("SERVICE_STOP_PENDING"); },
                delegate(string line) { Console.WriteLine(line); },
                delegate(string line) { Console.Error.WriteLine(line); });
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.Message);
            exitCode = 1;
        }
        Console.WriteLine("SERVICE_STOPPED");
        return exitCode;
    }

    private static void CompleteOrdinaryStop()
    {
        if (Interlocked.CompareExchange(ref stopStarted, 1, 0) != 0)
        {
            return;
        }
        ReportStatus(ServiceStopped, 0, 0, 0, 0, 0);
        StopFinished.Set();
    }

    private static void BeginStop()
    {
        if (Interlocked.CompareExchange(ref stopStarted, 1, 0) != 0)
        {
            return;
        }

        checkpoint = 1;
        ReportStopPending();
        Thread worker = new Thread(RunStopWorker);
        worker.IsBackground = false;
        worker.Start();
    }

    private static void RunStopWorker()
    {
        int exitCode = 1;
        try
        {
            exitCode = RunStopScript(GetStopScriptPath(), ReportStopPending, null, null);
        }
        catch
        {
            exitCode = 1;
        }
        finally
        {
            uint win32ExitCode = exitCode == 0 ? 0U : ErrorServiceSpecificError;
            ReportStatus(ServiceStopped, 0, 0, 0, win32ExitCode, (uint)Math.Max(0, exitCode));
            StopFinished.Set();
        }
    }

    private static int RunStopScript(
        string scriptPath,
        Action pendingAction,
        Action<string> outputAction,
        Action<string> errorAction)
    {
        if (!File.Exists(scriptPath))
        {
            throw new FileNotFoundException("The VM stop entry script was not found.", scriptPath);
        }

        string powershellPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell", "v1.0", "powershell.exe");
        ProcessStartInfo startInfo = new ProcessStartInfo();
        startInfo.FileName = powershellPath;
        startInfo.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" +
            scriptPath.Replace("\"", "\\\"") + "\"";
        startInfo.WorkingDirectory = Path.GetDirectoryName(scriptPath);
        startInfo.UseShellExecute = false;
        startInfo.CreateNoWindow = true;
        startInfo.RedirectStandardOutput = true;
        startInfo.RedirectStandardError = true;

        using (Process process = new Process())
        {
            process.StartInfo = startInfo;
            process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
            {
                if (eventArgs.Data != null && outputAction != null) { outputAction(eventArgs.Data); }
            };
            process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
            {
                if (eventArgs.Data != null && errorAction != null) { errorAction(eventArgs.Data); }
            };
            if (!process.Start())
            {
                throw new InvalidOperationException("Could not start the VM stop entry script.");
            }
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            while (!process.WaitForExit(5000))
            {
                pendingAction();
            }
            process.WaitForExit();
            return process.ExitCode;
        }
    }

    private static string GetStopScriptPath()
    {
        return Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "stop.ps1");
    }

    private static void ReportStopPending()
    {
        uint nextCheckpoint = unchecked(++checkpoint);
        ReportStatus(ServiceStopPending, 0, nextCheckpoint, 15000, 0, 0);
    }

    private static void ReportStatus(
        uint state,
        uint acceptedControls,
        uint statusCheckpoint,
        uint waitHint,
        uint win32ExitCode,
        uint serviceSpecificExitCode)
    {
        lock (StatusLock)
        {
            currentStatus.ServiceType = ServiceWin32OwnProcess;
            currentStatus.CurrentState = state;
            currentStatus.ControlsAccepted = acceptedControls;
            currentStatus.Win32ExitCode = win32ExitCode;
            currentStatus.ServiceSpecificExitCode = serviceSpecificExitCode;
            currentStatus.CheckPoint = statusCheckpoint;
            currentStatus.WaitHint = waitHint;
            if (!SetServiceStatus(statusHandle, ref currentStatus))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceStatus
    {
        public uint ServiceType;
        public uint CurrentState;
        public uint ControlsAccepted;
        public uint Win32ExitCode;
        public uint ServiceSpecificExitCode;
        public uint CheckPoint;
        public uint WaitHint;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ServiceTableEntry
    {
        [MarshalAs(UnmanagedType.LPWStr)]
        public string ServiceName;
        public ServiceMainFunction ServiceMain;
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void ServiceMainFunction(int argumentCount, IntPtr argumentVector);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate uint HandlerExFunction(uint control, uint eventType, IntPtr eventData, IntPtr context);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool StartServiceCtrlDispatcher([In] ServiceTableEntry[] serviceTable);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr RegisterServiceCtrlHandlerEx(
        string serviceName,
        HandlerExFunction handlerProc,
        IntPtr context);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetServiceStatus(IntPtr serviceStatusHandle, ref ServiceStatus serviceStatus);
}

public static class VmAutostopServiceConfiguration
{
    private const uint ScManagerConnect = 0x00000001;
    private const uint ScManagerCreateService = 0x00000002;
    private const uint ServiceQueryConfig = 0x00000001;
    private const uint ServiceChangeConfig = 0x00000002;
    private const uint ServiceQueryStatus = 0x00000004;
    private const uint ServiceStart = 0x00000010;
    private const uint ServiceWin32OwnProcess = 0x00000010;
    private const uint ServiceAutoStart = 0x00000002;
    private const uint ServiceErrorNormal = 0x00000001;
    private const uint ServiceStopped = 0x00000001;
    private const uint ServiceStartPending = 0x00000002;
    private const uint ServiceRunning = 0x00000004;
    private const uint ServiceConfigPreshutdownInfo = 7;
    private const uint PolicyCreateAccount = 0x00000010;
    private const uint PolicyLookupNames = 0x00000800;
    private const int ErrorInsufficientBuffer = 122;
    private const int ErrorServiceAlreadyRunning = 1056;
    private const int ErrorServiceDoesNotExist = 1060;

    public static void Configure(
        string serviceName,
        string displayName,
        string binaryPath,
        string accountName,
        string password,
        uint preshutdownTimeoutMilliseconds)
    {
        GrantServiceLogonRight(GetServiceLogonRightAccountName(accountName));
        IntPtr manager = OpenSCManager(null, null, ScManagerConnect | ScManagerCreateService);
        if (manager == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        IntPtr service = IntPtr.Zero;
        try
        {
            service = OpenService(manager, serviceName, ServiceQueryConfig | ServiceChangeConfig);
            if (service == IntPtr.Zero)
            {
                int error = Marshal.GetLastWin32Error();
                if (error != ErrorServiceDoesNotExist)
                {
                    throw new Win32Exception(error);
                }
                service = CreateService(
                    manager,
                    serviceName,
                    displayName,
                    ServiceQueryConfig | ServiceChangeConfig,
                    ServiceWin32OwnProcess,
                    ServiceAutoStart,
                    ServiceErrorNormal,
                    binaryPath,
                    null,
                    IntPtr.Zero,
                    null,
                    accountName,
                    password);
                if (service == IntPtr.Zero)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
            else if (!ChangeServiceConfig(
                service,
                ServiceWin32OwnProcess,
                ServiceAutoStart,
                ServiceErrorNormal,
                binaryPath,
                null,
                IntPtr.Zero,
                null,
                accountName,
                password,
                displayName))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            ServicePreshutdownInfo info = new ServicePreshutdownInfo();
            info.PreshutdownTimeout = preshutdownTimeoutMilliseconds;
            if (!ChangeServiceConfig2(service, ServiceConfigPreshutdownInfo, ref info))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
        finally
        {
            if (service != IntPtr.Zero) { CloseServiceHandle(service); }
            CloseServiceHandle(manager);
        }
    }

    public static bool EnsureStarted(string serviceName)
    {
        IntPtr manager = OpenSCManager(null, null, ScManagerConnect);
        if (manager == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        IntPtr service = IntPtr.Zero;
        try
        {
            service = OpenService(manager, serviceName, ServiceQueryStatus | ServiceStart);
            if (service == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            ServiceStatus status;
            if (!QueryServiceStatus(service, out status))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            if (status.CurrentState == ServiceRunning)
            {
                return false;
            }
            bool started = status.CurrentState == ServiceStartPending;
            if (!started && !StartService(service, 0, null))
            {
                int error = Marshal.GetLastWin32Error();
                if (error == ErrorServiceAlreadyRunning) { return false; }
                throw new Win32Exception(error);
            }
            DateTime deadline = DateTime.UtcNow.AddSeconds(15);
            do
            {
                Thread.Sleep(100);
                if (!QueryServiceStatus(service, out status))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                if (status.CurrentState == ServiceRunning) { return !started; }
                if (status.CurrentState == ServiceStopped)
                {
                    if (status.Win32ExitCode != 0)
                    {
                        throw new Win32Exception((int)status.Win32ExitCode);
                    }
                    throw new InvalidOperationException("The VM autostop service stopped during startup.");
                }
            }
            while (DateTime.UtcNow < deadline);
            throw new TimeoutException("The VM autostop service did not reach the running state within 15 seconds.");
        }
        finally
        {
            if (service != IntPtr.Zero) { CloseServiceHandle(service); }
            CloseServiceHandle(manager);
        }
    }

    public static string GetFingerprint(string serviceName)
    {
        IntPtr manager = OpenSCManager(null, null, ScManagerConnect);
        if (manager == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        IntPtr service = IntPtr.Zero;
        IntPtr configBuffer = IntPtr.Zero;
        IntPtr timeoutBuffer = IntPtr.Zero;
        try
        {
            service = OpenService(manager, serviceName, ServiceQueryConfig);
            if (service == IntPtr.Zero)
            {
                int error = Marshal.GetLastWin32Error();
                if (error == ErrorServiceDoesNotExist) { return null; }
                throw new Win32Exception(error);
            }

            uint bytesNeeded = 0;
            QueryServiceConfig(service, IntPtr.Zero, 0, out bytesNeeded);
            int queryError = Marshal.GetLastWin32Error();
            if (bytesNeeded == 0 || queryError != ErrorInsufficientBuffer)
            {
                throw new Win32Exception(queryError);
            }
            configBuffer = Marshal.AllocHGlobal((int)bytesNeeded);
            if (!QueryServiceConfig(service, configBuffer, bytesNeeded, out bytesNeeded))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            QueryServiceConfigData config = (QueryServiceConfigData)Marshal.PtrToStructure(
                configBuffer, typeof(QueryServiceConfigData));

            uint timeoutBytes = 0;
            QueryServiceConfig2(
                service, ServiceConfigPreshutdownInfo, IntPtr.Zero, 0, out timeoutBytes);
            int timeoutError = Marshal.GetLastWin32Error();
            if (timeoutBytes == 0 || timeoutError != ErrorInsufficientBuffer)
            {
                throw new Win32Exception(timeoutError);
            }
            timeoutBuffer = Marshal.AllocHGlobal((int)timeoutBytes);
            if (!QueryServiceConfig2(
                service, ServiceConfigPreshutdownInfo, timeoutBuffer, timeoutBytes, out timeoutBytes))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            ServicePreshutdownInfo timeout = (ServicePreshutdownInfo)Marshal.PtrToStructure(
                timeoutBuffer, typeof(ServicePreshutdownInfo));

            string accountName = Marshal.PtrToStringUni(config.ServiceStartName);
            if (!String.IsNullOrEmpty(accountName) &&
                (accountName.Equals(@".\DELL", StringComparison.OrdinalIgnoreCase) ||
                 accountName.EndsWith(@"\DELL", StringComparison.OrdinalIgnoreCase)))
            {
                accountName = "DELL";
            }
            string installedBinaryPath = Marshal.PtrToStringUni(config.BinaryPathName);
            return String.Format(
                "{0}|{1}|{2}|{3}|{4}",
                serviceName,
                accountName,
                config.StartType,
                installedBinaryPath,
                timeout.PreshutdownTimeout).ToLowerInvariant();
        }
        finally
        {
            if (timeoutBuffer != IntPtr.Zero) { Marshal.FreeHGlobal(timeoutBuffer); }
            if (configBuffer != IntPtr.Zero) { Marshal.FreeHGlobal(configBuffer); }
            if (service != IntPtr.Zero) { CloseServiceHandle(service); }
            CloseServiceHandle(manager);
        }
    }

    public static string ResolveAccountSid(string accountName)
    {
        return (new NTAccount(accountName).Translate(typeof(SecurityIdentifier)) as SecurityIdentifier).Value;
    }

    public static string GetServiceLogonRightAccountName(string accountName)
    {
        if (!String.IsNullOrEmpty(accountName) && accountName.StartsWith(@".\", StringComparison.Ordinal))
        {
            return Environment.MachineName + accountName.Substring(1);
        }
        return accountName;
    }

    private static void GrantServiceLogonRight(string accountName)
    {
        SecurityIdentifier sid = (SecurityIdentifier)new NTAccount(accountName).Translate(
            typeof(SecurityIdentifier));
        byte[] sidBytes = new byte[sid.BinaryLength];
        sid.GetBinaryForm(sidBytes, 0);
        IntPtr sidBuffer = Marshal.AllocHGlobal(sidBytes.Length);
        IntPtr rightBuffer = IntPtr.Zero;
        IntPtr policy = IntPtr.Zero;
        try
        {
            Marshal.Copy(sidBytes, 0, sidBuffer, sidBytes.Length);
            LsaObjectAttributes attributes = new LsaObjectAttributes();
            attributes.Length = (uint)Marshal.SizeOf(typeof(LsaObjectAttributes));
            uint status = LsaOpenPolicy(
                IntPtr.Zero,
                ref attributes,
                PolicyLookupNames | PolicyCreateAccount,
                out policy);
            ThrowIfLsaFailed(status);

            const string rightName = "SeServiceLogonRight";
            rightBuffer = Marshal.StringToHGlobalUni(rightName);
            LsaUnicodeString right = new LsaUnicodeString();
            right.Buffer = rightBuffer;
            right.Length = (ushort)(rightName.Length * sizeof(char));
            right.MaximumLength = (ushort)((rightName.Length + 1) * sizeof(char));
            status = LsaAddAccountRights(policy, sidBuffer, new LsaUnicodeString[] { right }, 1);
            ThrowIfLsaFailed(status);
        }
        finally
        {
            if (policy != IntPtr.Zero) { LsaClose(policy); }
            if (rightBuffer != IntPtr.Zero) { Marshal.FreeHGlobal(rightBuffer); }
            Marshal.FreeHGlobal(sidBuffer);
        }
    }

    private static void ThrowIfLsaFailed(uint status)
    {
        if (status != 0)
        {
            throw new Win32Exception((int)LsaNtStatusToWinError(status));
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ServicePreshutdownInfo
    {
        public uint PreshutdownTimeout;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct QueryServiceConfigData
    {
        public uint ServiceType;
        public uint StartType;
        public uint ErrorControl;
        public IntPtr BinaryPathName;
        public IntPtr LoadOrderGroup;
        public uint TagId;
        public IntPtr Dependencies;
        public IntPtr ServiceStartName;
        public IntPtr DisplayName;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceStatus
    {
        public uint ServiceType;
        public uint CurrentState;
        public uint ControlsAccepted;
        public uint Win32ExitCode;
        public uint ServiceSpecificExitCode;
        public uint CheckPoint;
        public uint WaitHint;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LsaObjectAttributes
    {
        public uint Length;
        public IntPtr RootDirectory;
        public IntPtr ObjectName;
        public uint Attributes;
        public IntPtr SecurityDescriptor;
        public IntPtr SecurityQualityOfService;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LsaUnicodeString
    {
        public ushort Length;
        public ushort MaximumLength;
        public IntPtr Buffer;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenSCManager(string machineName, string databaseName, uint desiredAccess);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenService(IntPtr manager, string serviceName, uint desiredAccess);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateService(
        IntPtr manager,
        string serviceName,
        string displayName,
        uint desiredAccess,
        uint serviceType,
        uint startType,
        uint errorControl,
        string binaryPathName,
        string loadOrderGroup,
        IntPtr tagId,
        string dependencies,
        string serviceStartName,
        string password);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ChangeServiceConfig(
        IntPtr service,
        uint serviceType,
        uint startType,
        uint errorControl,
        string binaryPathName,
        string loadOrderGroup,
        IntPtr tagId,
        string dependencies,
        string serviceStartName,
        string password,
        string displayName);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ChangeServiceConfig2(
        IntPtr service,
        uint infoLevel,
        ref ServicePreshutdownInfo info);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceConfig(
        IntPtr service,
        IntPtr serviceConfig,
        uint bufferSize,
        out uint bytesNeeded);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceConfig2(
        IntPtr service,
        uint infoLevel,
        IntPtr buffer,
        uint bufferSize,
        out uint bytesNeeded);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceStatus(IntPtr service, out ServiceStatus serviceStatus);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool StartService(IntPtr service, int argumentCount, string[] arguments);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseServiceHandle(IntPtr handle);

    [DllImport("advapi32.dll")]
    private static extern uint LsaOpenPolicy(
        IntPtr systemName,
        ref LsaObjectAttributes objectAttributes,
        uint desiredAccess,
        out IntPtr policyHandle);

    [DllImport("advapi32.dll")]
    private static extern uint LsaAddAccountRights(
        IntPtr policyHandle,
        IntPtr accountSid,
        LsaUnicodeString[] userRights,
        uint countOfRights);

    [DllImport("advapi32.dll")]
    private static extern uint LsaNtStatusToWinError(uint status);

    [DllImport("advapi32.dll")]
    private static extern uint LsaClose(IntPtr policyHandle);
}
