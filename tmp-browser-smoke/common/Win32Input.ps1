if (-not ("SmokeProbeUser32" -as [type])) {
  Add-Type @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class SmokeProbeUser32 {
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT {
        public uint type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion {
        [FieldOffset(0)]
        public MOUSEINPUT mi;
        [FieldOffset(0)]
        public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    private const uint INPUT_MOUSE = 0;
    private const uint INPUT_KEYBOARD = 1;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_UNICODE = 0x0004;
    private const ushort VK_CONTROL = 0x11;
    private const ushort VK_RETURN = 0x0D;
    private const ushort VK_TAB = 0x09;
    private const ushort VK_A = 0x41;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int count);

    private static void EnsureSent(uint sent, int expected, string label) {
        if (sent == (uint)expected) {
            return;
        }
        throw new Win32Exception(Marshal.GetLastWin32Error(), label + " sent " + sent + " of " + expected);
    }

    public static void SendLeftDown() {
        var inputs = new INPUT[1];
        inputs[0].type = INPUT_MOUSE;
        inputs[0].U.mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendLeftDown");
    }

    public static void SendLeftUp() {
        var inputs = new INPUT[1];
        inputs[0].type = INPUT_MOUSE;
        inputs[0].U.mi.dwFlags = MOUSEEVENTF_LEFTUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendLeftUp");
    }

    public static void SendLeftClick() {
        SendLeftDown();
        SendLeftUp();
    }

    public static void SendVirtualKey(ushort vk) {
        var inputs = new INPUT[2];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = vk;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = vk;
        inputs[1].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendVirtualKey");
    }

    public static void SendCtrlA() {
        var inputs = new INPUT[4];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_A;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_A;
        inputs[2].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_CONTROL;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlA");
    }

    public static void SendEnter() {
        SendVirtualKey(VK_RETURN);
    }

    public static void SendTab() {
        SendVirtualKey(VK_TAB);
    }

    public static void SendUnicodeString(string text) {
        if (String.IsNullOrEmpty(text)) {
            return;
        }

        var inputs = new INPUT[text.Length * 2];
        var i = 0;
        foreach (var ch in text) {
            inputs[i].type = INPUT_KEYBOARD;
            inputs[i].U.ki.wScan = ch;
            inputs[i].U.ki.dwFlags = KEYEVENTF_UNICODE;
            i += 1;

            inputs[i].type = INPUT_KEYBOARD;
            inputs[i].U.ki.wScan = ch;
            inputs[i].U.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
            i += 1;
        }

        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendUnicodeString");
    }
}
"@
}

function Get-SmokeWindowTitle([IntPtr]$Hwnd) {
  $builder = New-Object System.Text.StringBuilder 512
  [void][SmokeProbeUser32]::GetWindowTextW($Hwnd, $builder, $builder.Capacity)
  return $builder.ToString()
}

function Show-SmokeWindow([IntPtr]$Hwnd) {
  [void][SmokeProbeUser32]::ShowWindow($Hwnd, 5)
  [void][SmokeProbeUser32]::SetForegroundWindow($Hwnd)
}

function Invoke-SmokeClientClick([IntPtr]$Hwnd, [int]$X, [int]$Y) {
  $point = New-Object SmokeProbeUser32+POINT
  $point.X = $X
  $point.Y = $Y
  [void][SmokeProbeUser32]::ClientToScreen($Hwnd, [ref]$point)
  [void][SmokeProbeUser32]::SetCursorPos($point.X, $point.Y)
  Start-Sleep -Milliseconds 100
  [SmokeProbeUser32]::SendLeftDown()
  Start-Sleep -Milliseconds 80
  [SmokeProbeUser32]::SendLeftUp()
  return $point
}

function Send-SmokeCtrlA {
  [SmokeProbeUser32]::SendCtrlA()
}

function Send-SmokeEnter {
  [SmokeProbeUser32]::SendEnter()
}

function Send-SmokeTab {
  [SmokeProbeUser32]::SendTab()
}

function Send-SmokeText([string]$Text) {
  [SmokeProbeUser32]::SendUnicodeString($Text)
}
