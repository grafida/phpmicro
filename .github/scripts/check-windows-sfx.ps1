# The runtime half of check-windows-sfx.sh (grafida/grafida#91): runs the payloads
# the .sh built in -Work against the SFX. Windows PowerShell 5.1 or later.
param(
    [Parameter(Mandatory)] [string] $Sfx,
    [Parameter(Mandatory)] [string] $Work
)
$ErrorActionPreference = 'Stop'
Set-Location $Work

function Fail([string] $why) { Write-Host "FAIL: $why"; exit 1 }

function Concat([string] $out, [string[]] $parts) {
    $fs = [System.IO.File]::Create((Join-Path $Work $out))
    foreach ($part in $parts) { $b = [System.IO.File]::ReadAllBytes((Join-Path $Work $part)); $fs.Write($b, 0, $b.Length) }
    $fs.Close()
}

# Starts an executable the way a shell starts its worker: no shell, no window, all three streams
# redirected. -Stdin bytes are written while stdout is read, so a full pipe cannot deadlock.
function Invoke-Exe([string] $exe, [byte[]] $Stdin = $null, [string] $Arguments = '') {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $Work $exe
    $psi.Arguments = $Arguments
    $psi.WorkingDirectory = $Work
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = New-Object System.IO.MemoryStream
    $copy = $p.StandardOutput.BaseStream.CopyToAsync($out)
    $err = $p.StandardError.ReadToEndAsync()
    if ($Stdin) {
        $in = $p.StandardInput.BaseStream
        for ($o = 0; $o -lt $Stdin.Length; $o += 1048576) { $in.Write($Stdin, $o, [Math]::Min(1048576, $Stdin.Length - $o)) }
    }
    $p.StandardInput.Close()
    $copy.Wait()
    $p.WaitForExit()
    [pscustomobject]@{ Code = $p.ExitCode; Bytes = $out.ToArray(); Err = $err.Result }
}
function Text($r) { [System.Text.Encoding]::UTF8.GetString($r.Bytes).Trim() }
function Expect([string] $exe, [string] $expected, [string] $what) {
    $r = Invoke-Exe $exe
    $got = Text $r
    if ($r.Code -ne 0 -or $got -ne $expected) { Fail "$what (exit $($r.Code)): got '$got'; stderr: $($r.Err)" }
    Write-Host "ok: $what ($got)"
}

Copy-Item $Sfx (Join-Path $Work 'micro.sfx')

# 1. appended
Concat 'comb.exe' @('micro.sfx', 't.php')
Expect 'comb.exe' 'ok' 'appended payload'
Set-Content -NoNewline -Path (Join-Path $Work 'v.php') -Value '<?php echo PHP_VERSION, " ", PHP_SAPI, " ", implode(",", get_loaded_extensions());'
Concat 'version.exe' @('micro.sfx', 'v.php')
Write-Host "runtime: $(Text (Invoke-Exe 'version.exe'))"

# 2. <self without .exe>.phar, and 3. <self>.phar
Copy-Item micro.sfx a.exe; Copy-Item t.php a.phar
Expect 'a.exe' 'ok' 'sibling <self without .exe>.phar'
Copy-Item micro.sfx b.exe; Copy-Item t.php b.exe.phar
Expect 'b.exe' 'ok' 'sibling <self>.phar'

# 4. a real PHAR behind an extra-INI block
Copy-Item micro.sfx worker.exe; Copy-Item ini.phar worker.phar
Expect 'worker.exe' '345M payload phar' 'PHAR behind an extra-INI block'

# 4b. the same, started through an 8.3 short path (C:\Users\RUNNER~1\... on a runner): the
# sibling must still be read behind its extra-INI block, which needs its path spelled as PHP's
# realpath() spells it (grafida/grafida#91)
$long = Join-Path $Work 'a directory with a long name'
New-Item -ItemType Directory -Force $long | Out-Null
Copy-Item micro.sfx (Join-Path $long 'worker.exe'); Copy-Item ini.phar (Join-Path $long 'worker.phar')
$short = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($long).ShortPath
if ($short -eq $long) {
    Write-Host "SKIPPED: started through a short path (this volume makes no 8.3 names)"
} else {
    $psi = New-Object System.Diagnostics.ProcessStartInfo -ArgumentList (Join-Path $short 'worker.exe')
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $sp = [System.Diagnostics.Process]::Start($psi); $got = $sp.StandardOutput.ReadToEnd().Trim(); $sp.WaitForExit()
    if ($got -ne '345M payload phar') { Fail "started through the short path $short, the PHAR behind its extra-INI block reads '$got'" }
    Write-Host "ok: started through a short path ($short): $got"
}

# 5. signed with a throwaway self-signed certificate
Copy-Item micro.sfx signed.exe; Copy-Item ini.phar signed.phar
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=Grafida SFX Check' -CertStoreLocation Cert:\CurrentUser\My
try { $null = Set-AuthenticodeSignature -FilePath (Join-Path $Work 'signed.exe') -Certificate $cert }
finally { Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force }
if ((Get-Item signed.exe).Length -le (Get-Item micro.sfx).Length) { Fail 'signing appended no certificate table (the check would prove nothing)' }
Expect 'signed.exe' '345M payload phar' 'signed stub loads its sibling'

# 6. 50 MiB through STDIN and back out of STDOUT
Copy-Item micro.sfx echo.exe; Copy-Item echo.php echo.phar
$data = New-Object byte[] (50 * 1048576)
(New-Object System.Random 91).NextBytes($data)
$sha = [System.Security.Cryptography.SHA256]::Create()
$sent = [BitConverter]::ToString($sha.ComputeHash($data))
$t = [Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Exe 'echo.exe' -Stdin $data
$t.Stop()
$back = [BitConverter]::ToString($sha.ComputeHash($r.Bytes))
if ($r.Code -ne 0 -or $r.Bytes.Length -ne $data.Length -or $back -ne $sent) {
    Fail "stdio round trip: exit $($r.Code), $($r.Bytes.Length) of $($data.Length) bytes, hashes equal: $($back -eq $sent); stderr: $($r.Err)"
}
Write-Host "ok: 50 MiB through STDIN and STDOUT, byte-exact ($([int]$t.ElapsedMilliseconds) ms)"

# 7. the SFX's own children put no console window on the desktop
Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text; using System.Threading;
public static class ConsoleWatch {
    delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int obj, int child, uint thread, uint time);
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc proc, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool PeekMessage(out MSG m, IntPtr h, uint min, uint max, uint remove);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG m);
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }
    const uint EVENT_OBJECT_SHOW = 0x8002;
    static readonly List<string> seen = new List<string>();
    static volatile bool running;
    static Thread thread;
    static WinEventProc keep;
    // Console windows only: conhost's own, and Windows Terminal's (the default terminal on 11).
    static void OnShow(IntPtr hook, uint ev, IntPtr hwnd, int obj, int child, uint t, uint time) {
        if (obj != 0 || child != 0 || hwnd == IntPtr.Zero) return;
        var cls = new StringBuilder(256); GetClassName(hwnd, cls, 256);
        var name = cls.ToString();
        if (name != "ConsoleWindowClass" && name != "CASCADIA_HOSTING_WINDOW_CLASS") return;
        uint pid; GetWindowThreadProcessId(hwnd, out pid);
        lock (seen) seen.Add(name + " (pid " + pid + ")");
    }
    public static void Start() {
        lock (seen) seen.Clear();
        running = true;
        var ready = new ManualResetEvent(false);
        thread = new Thread(() => {
            keep = OnShow;
            var hook = SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_SHOW, IntPtr.Zero, keep, 0, 0, 0);
            ready.Set();
            MSG m;
            while (running) {
                while (PeekMessage(out m, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref m); DispatchMessage(ref m); }
                Thread.Sleep(5);
            }
            UnhookWinEvent(hook);
        });
        thread.IsBackground = true;
        thread.Start();
        ready.WaitOne();
    }
    public static string[] Stop() {
        Thread.Sleep(1000);   // a window shown at the very end still lands
        running = false;
        thread.Join();
        lock (seen) return seen.ToArray();
    }
}
'@

Copy-Item micro.sfx console.exe; Copy-Item console.php console.phar
$sapi = Text (Invoke-Exe 'console.exe' -Arguments 'sapi')
if ($sapi -ne 'micro') { Fail "SAPI '$sapi', expected 'micro' (PHP adds CREATE_NO_WINDOW only outside 'cli')" }
$windows = @{}
foreach ($mode in 'proc_open_array', 'proc_open_cmd', 'exec', 'control') {
    [ConsoleWatch]::Start()
    $r = Invoke-Exe 'console.exe' -Arguments $mode
    $windows[$mode] = @([ConsoleWatch]::Stop())
    if ($r.Code -ne 0) { Fail "console mode $mode exited $($r.Code); stderr: $($r.Err)" }
    Write-Host "  ${mode}: $(if ($windows[$mode].Count) { $windows[$mode] -join ', ' } else { 'no console window' })"
}
if ($windows['control'].Count -eq 0) {
    Fail 'the create_new_console control showed no console window either, so the check cannot tell: it needs an interactive desktop session (not SSH)'
}
foreach ($mode in 'proc_open_array', 'proc_open_cmd', 'exec') {
    if ($windows[$mode].Count) { Fail "a $mode child put a console window on the desktop: $($windows[$mode] -join ', ')" }
}
Write-Host 'ok: proc_open and exec children put no console window on the desktop (the create_new_console control does)'
