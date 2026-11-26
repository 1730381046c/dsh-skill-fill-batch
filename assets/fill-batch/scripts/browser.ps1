#requires -Version 5
<#
.SYNOPSIS
  Windows UI helpers for the fill-batch skill.

.DESCRIPTION
  Drives one logged-in Chromium browser window by screen coordinates.
  The page cannot be read through UIA/MSAA, so the caller captures a
  screenshot, locates the control visually, then clicks and pastes.

  Coordinates are SCREEN coordinates. `capture` writes the window bitmap
  whose pixel (0,0) equals the window rect's top-left, so image pixel
  (ix,iy) maps to screen (rect.left + ix, rect.top + iy).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File browser.ps1 -Action rect

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File browser.ps1 -Action capture -Out C:\tmp\shot.png

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File browser.ps1 -Action paste -X 1362 -Y 566 -Text 261380
#>
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('rect', 'capture', 'fg', 'click', 'paste', 'type', 'key', 'combo')]
  [string]$Action,

  [string]$Out,

  [int]$X = 0,
  [int]$Y = 0,
  [int]$Times = 1,

  [string]$Text = '',

  [byte]$Key = 0,
  [byte]$Mod = 0,

  [string]$ProcessName = '360se',
  [string]$TitleLike = 'ggfw.ybj.ln.gov.cn'
)

Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

$src = @'
using System;
using System.Text;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class FillBatchUi
{
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public InputUnion u; }
    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public UIntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public UIntPtr dwExtraInfo; }

    public static void Click(int x, int y)
    {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(140);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(60);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
    }

    public static void TypeUnicode(string s)
    {
        INPUT[] arr = new INPUT[s.Length * 2];
        for (int i = 0; i < s.Length; i++)
        {
            arr[i * 2] = new INPUT { type = 1, u = new InputUnion { ki = new KEYBDINPUT { wVk = 0, wScan = s[i], dwFlags = 0x0004 } } };
            arr[i * 2 + 1] = new INPUT { type = 1, u = new InputUnion { ki = new KEYBDINPUT { wVk = 0, wScan = s[i], dwFlags = 0x0004 | 0x0002 } } };
        }
        SendInput((uint)arr.Length, arr, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void Key(byte vk)
    {
        keybd_event(vk, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(40);
        keybd_event(vk, 0, 2, UIntPtr.Zero);
    }

    public static void Combo(byte mod, byte vk)
    {
        keybd_event(mod, 0, 0, UIntPtr.Zero);
        keybd_event(vk, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(30);
        keybd_event(vk, 0, 2, UIntPtr.Zero);
        keybd_event(mod, 0, 2, UIntPtr.Zero);
    }

    public static bool Capture(IntPtr h, string path)
    {
        RECT r; GetWindowRect(h, out r);
        int w = r.Right - r.Left, hh = r.Bottom - r.Top;
        using (Bitmap bmp = new Bitmap(w, hh))
        using (Graphics g = Graphics.FromImage(bmp))
        {
            IntPtr hdc = g.GetHdc();
            bool ok = PrintWindow(h, hdc, 2);
            g.ReleaseHdc(hdc);
            bmp.Save(path, ImageFormat.Png);
            return ok;
        }
    }
}
'@

try { Add-Type -TypeDefinition $src -ReferencedAssemblies System.Drawing -ErrorAction Stop } catch { }

function Get-BrowserWindow {
  $procs = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }
  if (-not $procs) { throw "no visible window for process '$ProcessName'" }
  if ($TitleLike) {
    $match = $procs | Where-Object { $_.MainWindowTitle -like "*$TitleLike*" }
    if ($match) { $procs = $match }
  }
  return ($procs | Select-Object -First 1)
}

function Wait-Foreground([IntPtr]$h, [int]$tries = 15) {
  for ($i = 0; $i -lt $tries; $i++) {
    if ([FillBatchUi]::GetForegroundWindow() -eq $h) { return $true }
    [FillBatchUi]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds 200
  }
  return ([FillBatchUi]::GetForegroundWindow() -eq $h)
}

$proc = Get-BrowserWindow
$hwnd = $proc.MainWindowHandle

switch ($Action) {
  'rect' {
    $r = New-Object FillBatchUi+RECT
    [FillBatchUi]::GetWindowRect($hwnd, [ref]$r) | Out-Null
    "window=$hwnd title=$($proc.MainWindowTitle)"
    "rect=$($r.Left),$($r.Top),$($r.Right),$($r.Bottom) size=$($r.Right - $r.Left)x$($r.Bottom - $r.Top)"
  }
  'capture' {
    if (-not $Out) { throw '-Out is required for capture' }
    $ok = [FillBatchUi]::Capture($hwnd, $Out)
    $r = New-Object FillBatchUi+RECT
    [FillBatchUi]::GetWindowRect($hwnd, [ref]$r) | Out-Null
    "capture=$ok path=$Out rect=$($r.Left),$($r.Top),$($r.Right),$($r.Bottom)"
  }
  'fg' {
    if ([FillBatchUi]::IsIconic($hwnd)) { [FillBatchUi]::ShowWindow($hwnd, 9) | Out-Null; Start-Sleep -Milliseconds 300 }
    [FillBatchUi]::ShowWindow($hwnd, 3) | Out-Null
    Start-Sleep -Milliseconds 300
    $ok = Wait-Foreground $hwnd
    "foreground=$ok window=$hwnd title=$($proc.MainWindowTitle)"
  }
  'click' {
    [FillBatchUi]::ShowWindow($hwnd, 3) | Out-Null
    if (-not (Wait-Foreground $hwnd)) { throw 'browser window is not foreground' }
    for ($i = 0; $i -lt $Times; $i++) {
      [FillBatchUi]::Click($X, $Y)
      Start-Sleep -Milliseconds 500
    }
    "clicked $Times at $X,$Y"
  }
  'paste' {
    [FillBatchUi]::ShowWindow($hwnd, 3) | Out-Null
    if (-not (Wait-Foreground $hwnd)) { throw 'browser window is not foreground' }
    if ($X -ne 0 -or $Y -ne 0) { [FillBatchUi]::Click($X, $Y); Start-Sleep -Milliseconds 700 }
    Set-Clipboard -Value $Text
    Start-Sleep -Milliseconds 150
    [FillBatchUi]::Combo(0x11, 0x56)
    Start-Sleep -Milliseconds 500
    "pasted length=$($Text.Length)"
  }
  'type' {
    if (-not (Wait-Foreground $hwnd)) { throw 'browser window is not foreground' }
    [FillBatchUi]::TypeUnicode($Text)
    Start-Sleep -Milliseconds 300
    "typed length=$($Text.Length)"
  }
  'key' {
    if (-not (Wait-Foreground $hwnd)) { throw 'browser window is not foreground' }
    [FillBatchUi]::Key($Key)
    "pressed vk=$Key"
  }
  'combo' {
    if (-not (Wait-Foreground $hwnd)) { throw 'browser window is not foreground' }
    [FillBatchUi]::Combo($Mod, $Key)
    "pressed mod=$Mod key=$Key"
  }
}
