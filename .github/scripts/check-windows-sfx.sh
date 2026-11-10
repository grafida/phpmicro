#!/usr/bin/env bash
#
# Check a Windows micro.sfx before it is published or pinned: what it is built
# for, what it imports, and that every payload mode and the stdio behaviour the
# consumers rely on work (grafida/grafida#91).
#
#   .github/scripts/check-windows-sfx.sh path/to/windows-x86_64.standard.sfx
#   .github/scripts/check-windows-sfx.sh --static-only path/to/…   (any OS)
#
# Environment:
#   EXPECT_SUBSYSTEM  2 (WINDOWS_GUI, the default: --enable-micro-win32) or 3 (CONSOLE)
#
# Needs a `php` with the phar extension on PATH (it reads the PE and builds the
# test PHAR). The runtime checks need Windows (Git Bash + Windows PowerShell, as
# on the windows-2022 runner) and run in check-windows-sfx.ps1; without
# --static-only, a non-Windows host is an error, never a silent skip.
#
# Static (check-windows-sfx-pe.php):
#   - PE32+, AMD64, the expected subsystem;
#   - imports (and delay-load imports) only from an allowlist of DLLs that ship
#     with Windows: no VCRUNTIME*, MSVCP*, api-ms-win-crt-* or ucrtbase, so the
#     SFX needs no Visual C++ runtime beside it;
#   - no overlay: the last section ends at the file size, so nothing is
#     appended (a signed stub's certificate table excepted).
#
# Runtime (check-windows-sfx.ps1):
#   1. appended payload (stock phpmicro behaviour; regression);
#   2. sibling "<self without .exe>.phar" (worker.exe -> worker.phar);
#   3. sibling "<self>.phar" (worker.exe -> worker.exe.phar);
#   4. a real PHAR behind an extra-INI block (magic fd f6 69 e6, 4-byte
#      big-endian length, ini text) as the sibling, with ini_get() proving the
#      block applied and a file read from inside the PHAR;
#   5. that stub signed with a throwaway self-signed certificate: the
#      certificate table lands past the last section, and the sibling must still
#      load;
#   6. stdio over real pipes: 50 MiB through STDIN back out of STDOUT,
#      byte-exact by SHA-256, from a .NET Process with all three streams
#      redirected (what a shell spawning the worker does);
#   7. no console window on the desktop for the SFX's own children (PHP adds
#      CREATE_NO_WINDOW outside the cli SAPI, and the SAPI here is "micro"): a
#      WinEvent hook records every console window shown (conhost's or Windows
#      Terminal's) while proc_open and exec children run; a create_new_console
#      child is the control that must show one. A child cannot tell by itself:
#      with Windows Terminal as the default terminal, every console has a
#      "visible" 0x0 PseudoConsoleWindow. Needs an interactive desktop session;
#      without one (e.g. over SSH) the control shows nothing and the check fails
#      saying so.

set -euo pipefail

static_only=0
if [ "${1:-}" = --static-only ]; then static_only=1; shift; fi
[ $# -eq 1 ] || { echo "usage: $0 [--static-only] path/to/micro.sfx" >&2; exit 64; }

HERE="$(cd "$(dirname "$0")" && pwd)"
SFX="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
EXPECT_SUBSYSTEM="${EXPECT_SUBSYSTEM:-2}"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== $SFX"
sha256sum "$SFX" 2>/dev/null || shasum -a 256 "$SFX"

php "$HERE/check-windows-sfx-pe.php" "$SFX" "$EXPECT_SUBSYSTEM" || fail "static checks"

if [ "$static_only" = 1 ]; then
    echo "== static checks passed (runtime checks not run: --static-only)"
    exit 0
fi

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) fail "the runtime checks need Windows; pass --static-only to run only the static ones" ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The payloads (PHP builds the PHAR; the PowerShell half only runs things).
printf '<?php echo "ok\n";' > "$WORK/t.php"
mkdir -p "$WORK/src"
cat > "$WORK/src/main.php" <<'PHP'
<?php
echo ini_get('memory_limit'), ' ', file_get_contents(__DIR__ . '/data.txt'), ' ', Phar::running(false) === '' ? 'no-phar' : 'phar', "\n";
PHP
printf 'payload' > "$WORK/src/data.txt"
# shellcheck disable=SC2016 # PHP code, not shell: nothing should expand
(cd "$WORK" && php -d phar.readonly=0 -r '
    $p = new Phar("w.phar");
    $p->buildFromDirectory("src");
    $p->setStub("<?php Phar::mapPhar(\"w.phar\"); require \"phar://w.phar/main.php\"; __HALT_COMPILER();");
    $ini = "memory_limit=345M\n";
    file_put_contents("ini.phar", "\xfd\xf6\x69\xe6" . pack("N", strlen($ini)) . $ini . file_get_contents("w.phar"));
')
# 6: STDIN to STDOUT, as a worker's frames travel.
printf '<?php stream_copy_to_stream(STDIN, STDOUT);' > "$WORK/echo.php"
# 7: the SFX starts one console child per mode, each alive long enough to be seen; the
# PowerShell half watches the desktop for console windows while it runs.
cat > "$WORK/console.php" <<'PHP'
<?php
$mode = $argv[1] ?? '';
$run = static function ($command, array $options = []): void {
    $p = proc_open($command, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, null, null, $options);
    fclose($pipes[0]);
    stream_get_contents($pipes[1]);
    fclose($pipes[1]); fclose($pipes[2]); proc_close($p);
};
switch ($mode) {
    case 'sapi':                // PHP adds CREATE_NO_WINDOW only outside the cli SAPI
        echo PHP_SAPI;
        break;
    case 'proc_open_array':     // no shell: the program itself
        $run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Milliseconds 1200']);
        break;
    case 'proc_open_cmd':       // a string: through cmd.exe, whose child shares its console
        $run('ping -n 3 127.0.0.1');
        break;
    case 'exec':                // popen(), behind exec/shell_exec
        shell_exec('reg query HKCU\Console & ping -n 3 127.0.0.1');
        break;
    case 'control':             // a console of its own: must be seen, or the check cannot tell
        $run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Milliseconds 1500'], ['create_new_console' => true]);
        break;
}
PHP

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$HERE/check-windows-sfx.ps1")" \
    -Sfx "$(cygpath -w "$SFX")" -Work "$(cygpath -w "$WORK")" || fail "runtime checks"

echo "== all checks passed"
