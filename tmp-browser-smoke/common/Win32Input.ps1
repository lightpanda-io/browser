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
    private const ushort VK_L = 0x4C;
    private const ushort VK_S = 0x53;
    private const ushort VK_T = 0x54;
    private const ushort VK_W = 0x57;
    private const ushort VK_MENU = 0x12;
    private const ushort VK_ESCAPE = 0x1B;
    private const ushort VK_F3 = 0x72;
    private const ushort VK_F5 = 0x74;
    private const ushort VK_OEM_COMMA = 0xBC;
    private const ushort VK_OEM_PLUS = 0xBB;
    private const ushort VK_P = 0x50;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetActiveWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SendMessageW(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

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

    public static void SendCtrlL() {
        var inputs = new INPUT[4];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_L;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_L;
        inputs[2].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_CONTROL;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlL");
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

    public static void SendCtrlShiftA() {
        var inputs = new INPUT[6];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_SHIFT;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_A;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_A;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[4].type = INPUT_KEYBOARD;
        inputs[4].U.ki.wVk = VK_SHIFT;
        inputs[4].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[5].type = INPUT_KEYBOARD;
        inputs[5].U.ki.wVk = VK_CONTROL;
        inputs[5].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlShiftA");
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

    public static void SendCtrlAltH() {
        var inputs = new INPUT[6];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_MENU;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_H;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_H;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[4].type = INPUT_KEYBOARD;
        inputs[4].U.ki.wVk = VK_MENU;
        inputs[4].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[5].type = INPUT_KEYBOARD;
        inputs[5].U.ki.wVk = VK_CONTROL;
        inputs[5].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlAltH");
    }

    public static void SendCtrlAltB() {
        var inputs = new INPUT[6];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_MENU;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_B;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_B;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[4].type = INPUT_KEYBOARD;
        inputs[4].U.ki.wVk = VK_MENU;
        inputs[4].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[5].type = INPUT_KEYBOARD;
        inputs[5].U.ki.wVk = VK_CONTROL;
        inputs[5].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlAltB");
    }

    public static void SendCtrlAltJ() {
        var inputs = new INPUT[6];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_MENU;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_J;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_J;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[4].type = INPUT_KEYBOARD;
        inputs[4].U.ki.wVk = VK_MENU;
        inputs[4].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[5].type = INPUT_KEYBOARD;
        inputs[5].U.ki.wVk = VK_CONTROL;
        inputs[5].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlAltJ");
    }

    public static void SendCtrlAltS() {
        var inputs = new INPUT[6];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_MENU;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_S;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_S;
        inputs[3].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[4].type = INPUT_KEYBOARD;
        inputs[4].U.ki.wVk = VK_MENU;
        inputs[4].U.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[5].type = INPUT_KEYBOARD;
        inputs[5].U.ki.wVk = VK_CONTROL;
        inputs[5].U.ki.dwFlags = KEYEVENTF_KEYUP;
        EnsureSent(SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))), inputs.Length, "SendCtrlAltS");
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

    public static void SendF5() {
        SendVirtualKey(VK_F5);
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

function Use-BareMetalInput {
  return -not [string]::IsNullOrWhiteSpace($env:LIGHTPANDA_BARE_METAL_INPUT)
}

function Use-HeadedMailboxInput {
  return -not [string]::IsNullOrWhiteSpace($env:LIGHTPANDA_WIN32_INPUT)
}

function Get-HeadedMailboxInputPath {
  if (Use-HeadedMailboxInput) {
    return $env:LIGHTPANDA_WIN32_INPUT
  }
  return $null
}

function Write-HeadedMailboxLine([string]$Line) {
  $path = Get-HeadedMailboxInputPath
  if (-not $path) {
    return $false
  }

  $parent = Split-Path -Parent $path
  if ($parent) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }

  $encoding = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::AppendAllText($path, $Line + [Environment]::NewLine, $encoding)
  return $true
}

function Send-HeadedKeyStroke([int]$Code, [int]$Modifiers = 0) {
  [void](Write-HeadedMailboxLine ("key|{0}|1|{1}" -f $Code, $Modifiers))
  [void](Write-HeadedMailboxLine ("key|{0}|0|{1}" -f $Code, $Modifiers))
}

function Send-HeadedPointerClick([int]$X, [int]$Y, [string]$Button = 'left', [int]$Modifiers = 0) {
  [void](Write-HeadedMailboxLine ("click|{0}|{1}|{2}|{3}" -f $X, $Y, $Button, $Modifiers))
}

function Send-HeadedWheel([int]$X, [int]$Y, [int]$Delta, [int]$Modifiers = 0) {
  [void](Write-HeadedMailboxLine ("wheel|{0}|{1}|0|{2}|{3}" -f $X, $Y, $Delta, $Modifiers))
}

function Send-SmokeAsciiText([string]$Text) {
  if (Use-HeadedMailboxInput) {
    [void](Write-HeadedMailboxLine ("text|{0}" -f $Text))
    return
  }
  if (Use-BareMetalInput) {
    foreach ($ch in $Text.ToCharArray()) {
      if ($ch -eq ' ') {
        Send-SmokeSpace
        Start-Sleep -Milliseconds 25
        continue
      }

      $upper = [char]::ToUpperInvariant($ch)
      Send-BareMetalKeyStroke -Code ([int][char]$upper)
      Start-Sleep -Milliseconds 25
    }
    return
  }

  [SmokeProbeUser32]::SendUnicodeString($Text)
}

function Get-BareMetalInputPath {
  if (Use-BareMetalInput) {
    return $env:LIGHTPANDA_BARE_METAL_INPUT
  }
  return $null
}

function Write-BareMetalInputLine([string]$Line) {
  $path = Get-BareMetalInputPath
  if (-not $path) {
    return $false
  }

  $parent = Split-Path -Parent $path
  if ($parent) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }

  $encoding = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::AppendAllText($path, $Line + [Environment]::NewLine, $encoding)
  return $true
}

function Send-BareMetalKeyStroke([int]$Code, [int]$Modifiers = 0) {
  [void](Write-BareMetalInputLine ("key|{0}|1|{1}" -f $Code, $Modifiers))
  [void](Write-BareMetalInputLine ("key|{0}|0|{1}" -f $Code, $Modifiers))
}

function Send-BareMetalPointerMove([int]$X, [int]$Y, [int]$Modifiers = 0) {
  [void](Write-BareMetalInputLine ("move|{0}|{1}|{2}" -f $X, $Y, $Modifiers))
}

function Send-BareMetalPointerClick([int]$X, [int]$Y, [string]$Button = 'left', [int]$Modifiers = 0) {
  Send-BareMetalPointerMove -X $X -Y $Y -Modifiers $Modifiers
  [void](Write-BareMetalInputLine ("pointer|{0}|{1}|{2}|1|{3}" -f $X, $Y, $Button, $Modifiers))
  [void](Write-BareMetalInputLine ("pointer|{0}|{1}|{2}|0|{3}" -f $X, $Y, $Button, $Modifiers))
}

function Send-BareMetalWheel([int]$X, [int]$Y, [int]$Delta, [int]$Modifiers = 0) {
  Send-BareMetalPointerMove -X $X -Y $Y -Modifiers $Modifiers
  [void](Write-BareMetalInputLine ("wheel|0|{0}|{1}" -f $Delta, $Modifiers))
}

function Get-SmokeWindowTitle([IntPtr]$Hwnd) {
  $builder = New-Object System.Text.StringBuilder 512
  [void][SmokeProbeUser32]::GetWindowTextW($Hwnd, $builder, $builder.Capacity)
  return $builder.ToString()
}

function Get-SmokeClientLParam([int]$X, [int]$Y) {
  $xPart = [int]($X -band 0xFFFF)
  $yPart = [int](($Y -band 0xFFFF) -shl 16)
  return [IntPtr]($xPart -bor $yPart)
}

function Show-SmokeWindow([IntPtr]$Hwnd) {
  [void][SmokeProbeUser32]::ShowWindow($Hwnd, 5)
  $HWND_TOPMOST = [IntPtr](-1)
  $HWND_NOTOPMOST = [IntPtr](-2)
  $SWP_NOMOVE = 0x0002
  $SWP_NOSIZE = 0x0001
  $SWP_SHOWWINDOW = 0x0040
  [void][SmokeProbeUser32]::SetWindowPos($Hwnd, $HWND_TOPMOST, 0, 0, 0, 0, ($SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_SHOWWINDOW))
  [void][SmokeProbeUser32]::SetWindowPos($Hwnd, $HWND_NOTOPMOST, 0, 0, 0, 0, ($SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_SHOWWINDOW))
  [void][SmokeProbeUser32]::SetActiveWindow($Hwnd)
  [void][SmokeProbeUser32]::SetForegroundWindow($Hwnd)
  Start-Sleep -Milliseconds 120
}

function Invoke-SmokeClientClickDirect([IntPtr]$Hwnd, [int]$X, [int]$Y) {
  $WM_MOUSEMOVE = 0x0200
  $WM_LBUTTONDOWN = 0x0201
  $WM_LBUTTONUP = 0x0202
  $MK_LBUTTON = 0x0001
  $lParam = Get-SmokeClientLParam -X $X -Y $Y
  [void][SmokeProbeUser32]::SendMessageW($Hwnd, $WM_MOUSEMOVE, [IntPtr]::Zero, $lParam)
  [void][SmokeProbeUser32]::SendMessageW($Hwnd, $WM_LBUTTONDOWN, [IntPtr]$MK_LBUTTON, $lParam)
  Start-Sleep -Milliseconds 30
  [void][SmokeProbeUser32]::SendMessageW($Hwnd, $WM_LBUTTONUP, [IntPtr]::Zero, $lParam)
}

function Send-SmokeWindowText([IntPtr]$Hwnd, [string]$Text) {
  $WM_CHAR = 0x0102
  foreach ($ch in $Text.ToCharArray()) {
    [void][SmokeProbeUser32]::SendMessageW($Hwnd, $WM_CHAR, [IntPtr][int][char]$ch, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 20
  }
}

function Send-SmokeWindowVirtualKey([IntPtr]$Hwnd, [int]$Vk) {
  $WM_KEYDOWN = 0x0100
  $WM_KEYUP = 0x0101
  [void][SmokeProbeUser32]::SendMessageW($Hwnd, $WM_KEYDOWN, [IntPtr]$Vk, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 20
  [void][SmokeProbeUser32]::SendMessageW($Hwnd, $WM_KEYUP, [IntPtr]$Vk, [IntPtr]::Zero)
}

function Send-SmokeWindowEnter([IntPtr]$Hwnd) {
  Send-SmokeWindowVirtualKey -Hwnd $Hwnd -Vk 13
  [void][SmokeProbeUser32]::SendMessageW($Hwnd, 0x0102, [IntPtr]13, [IntPtr]::Zero)
}

function Invoke-SmokeClientClick([IntPtr]$Hwnd, [int]$X, [int]$Y) {
  $point = New-Object SmokeProbeUser32+POINT
  $point.X = $X
  $point.Y = $Y
  if (Use-BareMetalInput) {
    Send-BareMetalPointerClick -X $X -Y $Y -Button 'left'
    return $point
  }
  if (Use-HeadedMailboxInput) {
    Send-HeadedPointerClick -X $X -Y $Y -Button 'left'
    return $point
  }

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
  if (Use-BareMetalInput) {
    Send-BareMetalWheel -X $X -Y $Y -Delta $Delta
    return $point
  }
  if (Use-HeadedMailboxInput) {
    Send-HeadedWheel -X $X -Y $Y -Delta $Delta
    return $point
  }

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
  if (Use-BareMetalInput) {
    Send-BareMetalWheel -X $X -Y $Y -Delta $Delta -Modifiers 2
    return $point
  }
  if (Use-HeadedMailboxInput) {
    Send-HeadedWheel -X $X -Y $Y -Delta $Delta -Modifiers 2
    return $point
  }

  [void][SmokeProbeUser32]::ClientToScreen($Hwnd, [ref]$point)
  [void][SmokeProbeUser32]::SetCursorPos($point.X, $point.Y)
  Start-Sleep -Milliseconds 100
  [SmokeProbeUser32]::SendCtrlWheel($Delta)
  return $point
}

function Send-SmokeCtrlA {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 65 -Modifiers 2
    return
  }
  [SmokeProbeUser32]::SendCtrlA()
}

function Send-SmokeCtrlF {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 70 -Modifiers 2
    return
  }
  [SmokeProbeUser32]::SendCtrlF()
}

function Send-SmokeCtrlD {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 68 -Modifiers 2
    return
  }
  [SmokeProbeUser32]::SendCtrlD()
}

function Send-SmokeCtrlH {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 72 -Modifiers 2
    return
  }
  [SmokeProbeUser32]::SendCtrlH()
}

function Send-SmokeCtrlJ {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 74 -Modifiers 2
    return
  }
  [SmokeProbeUser32]::SendCtrlJ()
}

function Send-SmokeCtrlL {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 76 -Modifiers 2
    return
  }
  [SmokeProbeUser32]::SendCtrlL()
}

function Send-SmokeCtrlComma {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 44 -Modifiers 2
    return
  }
  [SmokeProbeUser32]::SendCtrlComma()
}

function Send-SmokeCtrlT {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 84 -Modifiers 2
    return
  }
  [SmokeProbeUser32]::SendCtrlT()
}

function Send-SmokeCtrlW {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 87 -Modifiers 2
    return
  }
  [SmokeProbeUser32]::SendCtrlW()
}

function Send-SmokeCtrlTab {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 9 -Modifiers 2
    return
  }
  [SmokeProbeUser32]::SendCtrlTab()
}

function Send-SmokeCtrlShiftTab {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 9 -Modifiers 3
    return
  }
  [SmokeProbeUser32]::SendCtrlShiftTab()
}

function Send-SmokeCtrlDigit([int]$Digit) {
  if ($Digit -lt 1 -or $Digit -gt 9) {
    throw "Digit must be between 1 and 9"
  }
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code (48 + $Digit) -Modifiers 2
    return
  }
  [SmokeProbeUser32]::SendCtrlDigit([uint16](0x30 + $Digit))
}

function Send-SmokeCtrlPlus {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 43 -Modifiers 2
    return
  }
  [SmokeProbeUser32]::SendCtrlPlus()
}

function Send-SmokeCtrlShiftP {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 80 -Modifiers 3
    return
  }
  [SmokeProbeUser32]::SendCtrlShiftP()
}

function Send-SmokeCtrlShiftA {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 65 -Modifiers 3
    return
  }
  [SmokeProbeUser32]::SendCtrlShiftA()
}

function Send-SmokeCtrlShiftB {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 66 -Modifiers 3
    return
  }
  [SmokeProbeUser32]::SendCtrlShiftB()
}

function Send-SmokeCtrlShiftT {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 84 -Modifiers 3
    return
  }
  [SmokeProbeUser32]::SendCtrlShiftT()
}

function Send-SmokeCtrlShiftD {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 68 -Modifiers 3
    return
  }
  [SmokeProbeUser32]::SendCtrlShiftD()
}

function Send-SmokeCtrlAltH {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 72 -Modifiers 6
    return
  }
  [SmokeProbeUser32]::SendCtrlAltH()
}

function Send-SmokeCtrlAltB {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 66 -Modifiers 6
    return
  }
  [SmokeProbeUser32]::SendCtrlAltB()
}

function Send-SmokeCtrlAltJ {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 74 -Modifiers 6
    return
  }
  [SmokeProbeUser32]::SendCtrlAltJ()
}

function Send-SmokeCtrlAltS {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 83 -Modifiers 6
    return
  }
  [SmokeProbeUser32]::SendCtrlAltS()
}

function Send-SmokeAltHome {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 36 -Modifiers 4
    return
  }
  [SmokeProbeUser32]::SendAltHome()
}

function Send-SmokeEnter {
  if (Use-HeadedMailboxInput) {
    Send-HeadedKeyStroke -Code 13
    return
  }
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 13
    return
  }
  [SmokeProbeUser32]::SendEnter()
}

function Send-SmokeSpace {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 32
    return
  }
  [SmokeProbeUser32]::SendSpace()
}

function Send-SmokeEscape {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 27
    return
  }
  [SmokeProbeUser32]::SendEscape()
}

function Send-SmokeF3 {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 114
    return
  }
  [SmokeProbeUser32]::SendF3()
}

function Send-SmokeF5 {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 116
    return
  }
  [SmokeProbeUser32]::SendF5()
}

function Send-SmokeShiftF3 {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 114 -Modifiers 1
    return
  }
  [SmokeProbeUser32]::SendShiftF3()
}

function Send-SmokeTab {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 9
    return
  }
  [SmokeProbeUser32]::SendTab()
}

function Send-SmokeUp {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 38
    return
  }
  [SmokeProbeUser32]::SendUp()
}

function Send-SmokeDown {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 40
    return
  }
  [SmokeProbeUser32]::SendDown()
}

function Send-SmokeLeft {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 37
    return
  }
  [SmokeProbeUser32]::SendVirtualKey([uint16]0x25)
}

function Send-SmokeRight {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 39
    return
  }
  [SmokeProbeUser32]::SendVirtualKey([uint16]0x27)
}

function Send-SmokeHome {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 36
    return
  }
  [SmokeProbeUser32]::SendHome()
}

function Send-SmokeEnd {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 35
    return
  }
  [SmokeProbeUser32]::SendEnd()
}

function Send-SmokePageUp {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 33
    return
  }
  [SmokeProbeUser32]::SendPageUp()
}

function Send-SmokePageDown {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 34
    return
  }
  [SmokeProbeUser32]::SendPageDown()
}

function Send-SmokeDelete {
  if (Use-BareMetalInput) {
    Send-BareMetalKeyStroke -Code 46
    return
  }
  [SmokeProbeUser32]::SendDelete()
}

function Send-SmokeText([string]$Text) {
  if (Use-BareMetalInput) {
    foreach ($ch in $Text.ToCharArray()) {
      $code = [int][char]$ch
      if ($code -eq 10 -or $code -eq 13) {
        Send-BareMetalKeyStroke -Code 13
      } else {
        Send-BareMetalKeyStroke -Code $code
      }
    }
    return
  }
  [SmokeProbeUser32]::SendUnicodeString($Text)
}
