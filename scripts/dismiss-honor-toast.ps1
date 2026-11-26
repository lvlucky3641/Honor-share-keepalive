param(
    [int]$TimeoutMilliseconds = 3000
)

$ErrorActionPreference = 'Stop'

Add-Type @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class HonorToastWindow
{
    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(
        IntPtr window,
        StringBuilder className,
        int maxLength
    );

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(
        IntPtr window,
        out uint processId
    );

    [DllImport("user32.dll")]
    private static extern bool PostMessage(
        IntPtr window,
        uint message,
        IntPtr wParam,
        IntPtr lParam
    );

    public static IntPtr[] Find(string processName, string className)
    {
        var matches = new List<IntPtr>();

        EnumWindows(
            (window, parameter) =>
            {
                if (!IsWindowVisible(window))
                {
                    return true;
                }

                var currentClass = new StringBuilder(256);
                GetClassName(window, currentClass, currentClass.Capacity);
                if (currentClass.ToString() != className)
                {
                    return true;
                }

                uint processId;
                GetWindowThreadProcessId(window, out processId);

                try
                {
                    if (Process.GetProcessById((int)processId).ProcessName == processName)
                    {
                        matches.Add(window);
                    }
                }
                catch
                {
                    // The owning process may exit while its window is being inspected.
                }

                return true;
            },
            IntPtr.Zero
        );

        return matches.ToArray();
    }

    public static void Close(IntPtr window)
    {
        const uint WM_CLOSE = 0x0010;
        PostMessage(window, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
    }
}
'@

$deadline = (Get-Date).AddMilliseconds($TimeoutMilliseconds)

do {
    $windows = @(
        [HonorToastWindow]::Find(
            'HnTrustCircleService',
            'SuperNotificationToastDlg'
        )
    )

    if ($windows.Count -gt 0) {
        foreach ($window in $windows) {
            [HonorToastWindow]::Close($window)
        }
        exit 0
    }

    Start-Sleep -Milliseconds 100
}
while ((Get-Date) -lt $deadline)

exit 2
