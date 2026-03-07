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
    private const uint MOUSEEVENTF_WHEEL = 0x0800;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_UNICODE = 0x0004;
    private const ushort VK_CONTROL = 0x11;
    private const ushort VK_SHIFT = 0x10;
    private const ushort VK_SPACE = 0x20;
    private const ushort VK_RETURN = 0x0D;
    private const ushort VK_TAB = 0x09;
    private const ushort VK_PRIOR = 0x21;
    private const ushort VK_NEXT = 0x22;
    private const ushort VK_END = 0x23;
    private const ushort VK_HOME = 0x24;
    private const ushort VK_LEFT = 0x25;
    private const ushort VK_UP = 0x26;
    private const ushort VK_RIGHT = 0x27;
    private const ushort VK_DOWN = 0x28;
    private const ushort VK_DELETE = 0x2E;
    private const ushort VK_A = 0x41;
    private const ushort VK_B = 0x42;
    private const ushort VK_D = 0x44;
    private const ushort VK_F = 0x46;
    private const ushort VK_H = 0x48;
    private const ushort VK_J = 0x4A;
    private const ushort VK_T = 0x54;
    private const ushort VK_W = 0x57;
    private const ushort VK_MENU = 0x12;
    private const ushort VK_ESCAPE = 0x1B;
    private const ushort VK_F3 = 0x72;
    private const ushort VK_OEM_COMMA = 0xBC;
    private const ushort VK_OEM_PLUS = 0xBB;
    private const ushort VK_P = 0x50;

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

    public static void SendMouseWheel(int delta) {
        var inputs = new INPUT[1];
        inputs[0].type = INPUT_MOUSE;
        inputs[0].U.mi.dwFlags = MOUSEEVENTF_WHEEL;
        inputs[0].U.mi.mouseData = (uint)delta;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendMouseWheel");
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

    public static void SendCtrlF() {
        var inputs = new INPUT[4];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_F;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_F;
        inputs[2].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_CONTROL;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlF");
    }

    public static void SendCtrlD() {
        var inputs = new INPUT[4];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_D;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_D;
        inputs[2].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_CONTROL;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlD");
    }

    public static void SendCtrlH() {
        var inputs = new INPUT[4];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_H;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_H;
        inputs[2].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_CONTROL;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlH");
    }

    public static void SendCtrlJ() {
        var inputs = new INPUT[4];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_J;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_J;
        inputs[2].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_CONTROL;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlJ");
    }

    public static void SendCtrlComma() {
        var inputs = new INPUT[4];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_OEM_COMMA;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_OEM_COMMA;
        inputs[2].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_CONTROL;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlComma");
    }

    public static void SendCtrlT() {
        var inputs = new INPUT[4];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_T;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_T;
        inputs[2].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_CONTROL;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlT");
    }

    public static void SendCtrlW() {
        var inputs = new INPUT[4];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_W;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_W;
        inputs[2].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_CONTROL;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlW");
    }

    public static void SendCtrlTab() {
        var inputs = new INPUT[4];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_TAB;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_TAB;
        inputs[2].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_CONTROL;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlTab");
    }

    public static void SendCtrlShiftTab() {
        var inputs = new INPUT[6];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_SHIFT;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_TAB;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_TAB;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[4].type = INPUT_KEYBOARD;
        inputs[4].U.ki.wVk = VK_SHIFT;
        inputs[4].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[5].type = INPUT_KEYBOARD;
        inputs[5].U.ki.wVk = VK_CONTROL;
        inputs[5].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlShiftTab");
    }

    public static void SendCtrlDigit(ushort vk) {
        var inputs = new INPUT[4];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = vk;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = vk;
        inputs[2].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_CONTROL;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlDigit");
    }

    public static void SendCtrlPlus() {
        var inputs = new INPUT[4];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_OEM_PLUS;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_OEM_PLUS;
        inputs[2].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_CONTROL;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlPlus");
    }

    public static void SendCtrlShiftP() {
        var inputs = new INPUT[6];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_SHIFT;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_P;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_P;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[4].type = INPUT_KEYBOARD;
        inputs[4].U.ki.wVk = VK_SHIFT;
        inputs[4].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[5].type = INPUT_KEYBOARD;
        inputs[5].U.ki.wVk = VK_CONTROL;
        inputs[5].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlShiftP");
    }

    public static void SendCtrlShiftB() {
        var inputs = new INPUT[6];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_SHIFT;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_B;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_B;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[4].type = INPUT_KEYBOARD;
        inputs[4].U.ki.wVk = VK_SHIFT;
        inputs[4].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[5].type = INPUT_KEYBOARD;
        inputs[5].U.ki.wVk = VK_CONTROL;
        inputs[5].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlShiftB");
    }

    public static void SendCtrlShiftT() {
        var inputs = new INPUT[6];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_SHIFT;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_T;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_T;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[4].type = INPUT_KEYBOARD;
        inputs[4].U.ki.wVk = VK_SHIFT;
        inputs[4].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[5].type = INPUT_KEYBOARD;
        inputs[5].U.ki.wVk = VK_CONTROL;
        inputs[5].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlShiftT");
    }

    public static void SendCtrlShiftD() {
        var inputs = new INPUT[6];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_SHIFT;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_D;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_D;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[4].type = INPUT_KEYBOARD;
        inputs[4].U.ki.wVk = VK_SHIFT;
        inputs[4].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[5].type = INPUT_KEYBOARD;
        inputs[5].U.ki.wVk = VK_CONTROL;
        inputs[5].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlShiftD");
    }

    public static void SendAltHome() {
        var inputs = new INPUT[4];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_MENU;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_HOME;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_HOME;
        inputs[2].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_MENU;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendAltHome");
    }

    public static void SendCtrlWheel(int delta) {
        var inputs = new INPUT[3];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_MOUSE;
        inputs[1].U.mi.dwFlags = MOUSEEVENTF_WHEEL;
        inputs[1].U.mi.mouseData = (uint)delta;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_CONTROL;
        inputs[2].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlWheel");
    }

    public static void SendEscape() {
        SendVirtualKey(VK_ESCAPE);
    }

    public static void SendF3() {
        SendVirtualKey(VK_F3);
    }

    public static void SendShiftF3() {
        var inputs = new INPUT[4];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_SHIFT;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_F3;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_F3;
        inputs[2].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_SHIFT;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendShiftF3");
    }

    public static void SendEnter() {
        SendVirtualKey(VK_RETURN);
    }

    public static void SendSpace() {
        SendVirtualKey(VK_SPACE);
    }

    public static void SendTab() {
        SendVirtualKey(VK_TAB);
    }

    public static void SendUp() {
        SendVirtualKey(VK_UP);
    }

    public static void SendDown() {
        SendVirtualKey(VK_DOWN);
    }

    public static void SendHome() {
        SendVirtualKey(VK_HOME);
    }

    public static void SendEnd() {
        SendVirtualKey(VK_END);
    }

    public static void SendPageUp() {
        SendVirtualKey(VK_PRIOR);
    }

    public static void SendPageDown() {
        SendVirtualKey(VK_NEXT);
    }

    public static void SendDelete() {
        SendVirtualKey(VK_DELETE);
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

function Invoke-SmokeClientWheel([IntPtr]$Hwnd, [int]$X, [int]$Y, [int]$Delta) {
  $point = New-Object SmokeProbeUser32+POINT
  $point.X = $X
  $point.Y = $Y
  [void][SmokeProbeUser32]::ClientToScreen($Hwnd, [ref]$point)
  [void][SmokeProbeUser32]::SetCursorPos($point.X, $point.Y)
  Start-Sleep -Milliseconds 100
  [SmokeProbeUser32]::SendMouseWheel($Delta)
  return $point
}

function Invoke-SmokeClientCtrlWheel([IntPtr]$Hwnd, [int]$X, [int]$Y, [int]$Delta) {
  $point = New-Object SmokeProbeUser32+POINT
  $point.X = $X
  $point.Y = $Y
  [void][SmokeProbeUser32]::ClientToScreen($Hwnd, [ref]$point)
  [void][SmokeProbeUser32]::SetCursorPos($point.X, $point.Y)
  Start-Sleep -Milliseconds 100
  [SmokeProbeUser32]::SendCtrlWheel($Delta)
  return $point
}

function Send-SmokeCtrlA {
  [SmokeProbeUser32]::SendCtrlA()
}

function Send-SmokeCtrlF {
  [SmokeProbeUser32]::SendCtrlF()
}

function Send-SmokeCtrlD {
  [SmokeProbeUser32]::SendCtrlD()
}

function Send-SmokeCtrlH {
  [SmokeProbeUser32]::SendCtrlH()
}

function Send-SmokeCtrlJ {
  [SmokeProbeUser32]::SendCtrlJ()
}

function Send-SmokeCtrlComma {
  [SmokeProbeUser32]::SendCtrlComma()
}

function Send-SmokeCtrlT {
  [SmokeProbeUser32]::SendCtrlT()
}

function Send-SmokeCtrlW {
  [SmokeProbeUser32]::SendCtrlW()
}

function Send-SmokeCtrlTab {
  [SmokeProbeUser32]::SendCtrlTab()
}

function Send-SmokeCtrlShiftTab {
  [SmokeProbeUser32]::SendCtrlShiftTab()
}

function Send-SmokeCtrlDigit([int]$Digit) {
  if ($Digit -lt 1 -or $Digit -gt 9) {
    throw "Digit must be between 1 and 9"
  }
  [SmokeProbeUser32]::SendCtrlDigit([uint16](0x30 + $Digit))
}

function Send-SmokeCtrlPlus {
  [SmokeProbeUser32]::SendCtrlPlus()
}

function Send-SmokeCtrlShiftP {
  [SmokeProbeUser32]::SendCtrlShiftP()
}

function Send-SmokeCtrlShiftB {
  [SmokeProbeUser32]::SendCtrlShiftB()
}

function Send-SmokeCtrlShiftT {
  [SmokeProbeUser32]::SendCtrlShiftT()
}

function Send-SmokeCtrlShiftD {
  [SmokeProbeUser32]::SendCtrlShiftD()
}

function Send-SmokeAltHome {
  [SmokeProbeUser32]::SendAltHome()
}

function Send-SmokeEnter {
  [SmokeProbeUser32]::SendEnter()
}

function Send-SmokeSpace {
  [SmokeProbeUser32]::SendSpace()
}

function Send-SmokeEscape {
  [SmokeProbeUser32]::SendEscape()
}

function Send-SmokeF3 {
  [SmokeProbeUser32]::SendF3()
}

function Send-SmokeShiftF3 {
  [SmokeProbeUser32]::SendShiftF3()
}

function Send-SmokeTab {
  [SmokeProbeUser32]::SendTab()
}

function Send-SmokeUp {
  [SmokeProbeUser32]::SendUp()
}

function Send-SmokeDown {
  [SmokeProbeUser32]::SendDown()
}

function Send-SmokeLeft {
  [SmokeProbeUser32]::SendVirtualKey([uint16]0x25)
}

function Send-SmokeRight {
  [SmokeProbeUser32]::SendVirtualKey([uint16]0x27)
}

function Send-SmokeHome {
  [SmokeProbeUser32]::SendHome()
}

function Send-SmokeEnd {
  [SmokeProbeUser32]::SendEnd()
}

function Send-SmokePageUp {
  [SmokeProbeUser32]::SendPageUp()
}

function Send-SmokePageDown {
  [SmokeProbeUser32]::SendPageDown()
}

function Send-SmokeDelete {
  [SmokeProbeUser32]::SendDelete()
}

function Send-SmokeText([string]$Text) {
  [SmokeProbeUser32]::SendUnicodeString($Text)
}
