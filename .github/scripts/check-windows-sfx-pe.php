<?php

/*
 * The static half of check-windows-sfx.sh: reads a PE file and checks its
 * machine, subsystem, imports and overlay (grafida/grafida#91).
 *
 *   php check-windows-sfx-pe.php micro.sfx [expected subsystem, default 2]
 *
 * Exit 0 when every check passes, 1 otherwise. Prints what it found.
 */

declare(strict_types=1);

$path     = $argv[1] ?? '';
$expected = (int) ($argv[2] ?? 2);
$bytes    = @file_get_contents($path);

if ($bytes === false || strlen($bytes) < 0x40 || substr($bytes, 0, 2) !== 'MZ') {
    fwrite(STDERR, "FAIL: $path is not a PE file\n");
    exit(1);
}

$u16 = static fn (int $o): int => unpack('v', $bytes, $o)[1];
$u32 = static fn (int $o): int => unpack('V', $bytes, $o)[1];
$failures = [];
$fail = static function (string $why) use (&$failures): void { $failures[] = $why; };

$pe = $u32(0x3C);
if (substr($bytes, $pe, 4) !== "PE\0\0") {
    fwrite(STDERR, "FAIL: no PE signature\n");
    exit(1);
}
$coff      = $pe + 4;
$machine   = $u16($coff);
$sections  = $u16($coff + 2);
$optSize   = $u16($coff + 16);
$opt       = $coff + 20;
$magic     = $u16($opt);
$subsystem = $u16($opt + 68);

printf("machine 0x%04x, optional header 0x%03x, subsystem %d\n", $machine, $magic, $subsystem);
$machine === 0x8664 || $fail(sprintf('machine 0x%04x, expected 0x8664 (AMD64)', $machine));
$magic === 0x20B || $fail(sprintf('optional header 0x%x, expected 0x20b (PE32+)', $magic));
$subsystem === $expected || $fail("subsystem $subsystem, expected $expected (2 = WINDOWS_GUI, 3 = CONSOLE)");

// Data directories (PE32+: they start at offset 112 of the optional header).
$dir = static fn (int $i): array => [$u32($opt + 112 + 8 * $i), $u32($opt + 112 + 8 * $i + 4)];

// Section table, and an RVA -> file offset map.
$table = [];
$end   = 0;
for ($i = 0, $s = $opt + $optSize; $i < $sections; $i++, $s += 40) {
    $table[] = [
        'name' => rtrim(substr($bytes, $s, 8), "\0"),
        'va'   => $u32($s + 12),
        'vs'   => $u32($s + 8),
        'raw'  => $u32($s + 16),
        'ptr'  => $u32($s + 20),
    ];
    $last = $table[$i];
    // phpmicro's sfxsize: max(PointerToRawData + SizeOfRawData) over the sections.
    $end = max($end, $last['ptr'] + $last['raw']);
}
$offset = static function (int $rva) use ($table): ?int {
    foreach ($table as $s) {
        if ($rva >= $s['va'] && $rva < $s['va'] + max($s['vs'], $s['raw'])) {
            return $rva - $s['va'] + $s['ptr'];
        }
    }

    return null;
};
$cstring = static function (int $rva) use ($bytes, $offset): string {
    $o = $offset($rva);

    return $o === null ? '?' : substr($bytes, $o, strcspn($bytes, "\0", $o));
};

// Imports: IMAGE_IMPORT_DESCRIPTOR (20 bytes, Name RVA at +12) and the delay-load
// descriptors (32 bytes, DllNameRVA at +4), each list ended by an all-zero entry.
$imports = [];
foreach ([[1, 20, 12], [13, 32, 4]] as [$index, $size, $nameAt]) {
    [$rva] = $dir($index);
    $o = $rva === 0 ? null : $offset($rva);
    for (; $o !== null && trim(substr($bytes, $o, $size), "\0") !== ''; $o += $size) {
        $imports[] = $cstring($u32($o + $nameAt)) . ($index === 13 ? ' (delay-load)' : '');
    }
}
sort($imports, SORT_FLAG_CASE | SORT_STRING);
echo 'imports: ', implode(', ', $imports), "\n";

// DLLs that ship with every Windows 10/11. A DLL not on this list fails the
// check: whoever adds an extension that links one decides whether it is fine.
$system = ['advapi32', 'bcrypt', 'comctl32', 'crypt32', 'dbghelp', 'dnsapi', 'gdi32', 'iphlpapi',
    'kernel32', 'ncrypt', 'normaliz', 'ntdll', 'ole32', 'oleaut32', 'psapi', 'rpcrt4', 'secur32',
    'shell32', 'shlwapi', 'user32', 'userenv', 'version', 'winmm', 'wldap32', 'ws2_32'];
foreach ($imports as $import) {
    $dll = strtolower(preg_replace('/\.dll( \(delay-load\))?$/i', '', $import));
    if (preg_match('/^(vcruntime|msvcp|api-ms-win-crt-|ucrtbase)/', $dll)) {
        $fail("imports $import: the Visual C++ runtime, which a clean Windows may lack");
    } elseif (!in_array($dll, $system, true)) {
        $fail("imports $import, which is not on the list of DLLs that ship with Windows");
    }
}

// Overlay: anything past the last section, other than a certificate table
// (data directory 4; its "RVA" is a file offset) that ends the file.
[$certAt, $certSize] = $dir(4);
$size    = strlen($bytes);
$covered = ($certAt >= $end && $certAt + $certSize === $size) ? $size : $end;
printf("sections end at %d, file is %d bytes%s\n", $end, $size, $certSize > 0 ? ", certificate table $certSize bytes at $certAt" : '');
$covered === $size || $fail(sprintf('%d bytes past the last section (an appended payload?)', $size - $covered));

foreach ($failures as $why) {
    fwrite(STDERR, "FAIL: $why\n");
}
if ($failures !== []) {
    exit(1);
}
echo "ok: PE32+ AMD64, subsystem $subsystem, system DLLs only, no overlay\n";
