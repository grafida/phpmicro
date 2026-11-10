<?php

/*
 * Windows builds only: make a micro.sfx's child processes get no console window
 * (grafida/grafida#91).
 *
 *   php keep-create-no-window.php <static-php-cli>/src/globals/patch/php-src-patches
 *
 * Upstream PHP adds CREATE_NO_WINDOW to every proc_open() and popen() child
 * outside the cli SAPI (ext/standard/proc_open.c, TSRM/tsrm_win32.c). The
 * cli_checks patch static-php-cli applies makes "micro" count as "cli" there too,
 * so a micro child shares its parent's console, as a php.exe child would. But the
 * Windows SFX here is a GUI-subsystem build (--enable-micro-win32): it has no
 * console to share, so every console child (cmd, reg, powershell) got a new,
 * visible one, a Windows Terminal window on Windows 11. Dropping exactly those two
 * hunks from every cli_checks_*.patch restores upstream PHP's behaviour for
 * micro; the patch's other hunks (FFI, opcache, readline, ...) stay.
 *
 * It fails when a patch no longer has the hunks as expected, so a static-php-cli
 * bump that changes them stops the build instead of silently shipping a runtime
 * whose children flash consoles again. check-windows-sfx.sh proves the result.
 */

declare(strict_types=1);

$dir = rtrim($argv[1] ?? '', '/\\');
$files = glob($dir . '/cli_checks_*.patch') ?: [];
if ($files === []) {
    fwrite(STDERR, "no cli_checks_*.patch in '{$dir}'\n");
    exit(1);
}

// The two hunks, by the file they patch, and the line each one adds.
$drop = [
    'TSRM/tsrm_win32.c'        => 'strcmp(sapi_module.name, "micro") != 0',
    'ext/standard/proc_open.c' => 'strcmp(sapi_module.name, "micro") != 0',
];

foreach ($files as $file) {
    $text = (string) file_get_contents($file);
    // Split into "diff --git" sections, keeping each header with its section.
    $sections = preg_split('/^(?=diff --git )/m', $text) ?: [];
    $kept = [];
    $dropped = [];
    foreach ($sections as $section) {
        $target = preg_match('#^diff --git a/(\S+) b/#', $section, $m) ? $m[1] : null;
        if ($target !== null && isset($drop[$target])) {
            if (!str_contains($section, $drop[$target]) || !str_contains($section, 'CREATE_NO_WINDOW')) {
                fwrite(STDERR, basename($file) . ": the {$target} hunk is not the expected one; check it by hand\n");
                exit(1);
            }
            $dropped[] = $target;
            continue;
        }
        $kept[] = $section;
    }
    sort($dropped);
    $expected = array_keys($drop);
    sort($expected);
    if ($dropped !== $expected) {
        fwrite(STDERR, basename($file) . ': dropped [' . implode(', ', $dropped) . '], expected [' . implode(', ', $expected) . "]\n");
        exit(1);
    }
    file_put_contents($file, implode('', $kept));
    echo basename($file), ': kept CREATE_NO_WINDOW for micro in ', implode(' and ', $dropped), "\n";
}
