#!/usr/bin/env bash
#
# Check a Linux micro.sfx before it is published: how it is linked, and that
# every payload mode the consumers rely on works.
#
#   .github/scripts/check-linux-sfx.sh path/to/micro.sfx
#
# Needs a `php` with the phar extension on PATH (to build the test PHAR) and
# binutils (readelf, objdump). Runs in a throwaway directory.
#
# Linking: dynamically linked against glibc and the GCC runtime (libgcc_s,
# which every glibc distribution ships as a base package) and nothing else, with no glibc symbol newer than GLIBC_MAX (2.35, the floor of the
# Grafida shell). A fully static binary fails the check on purpose: static-php-cli
# hard-codes `--enable-micro=all-static` on Linux, and a missing override would
# otherwise ship a static glibc without anyone noticing.
#
# Payload modes:
#   1. appended payload (stock phpmicro behaviour; regression);
#   2. sibling "<self>.phar" (the sibling-phar patch, never smoke-tested on
#      Linux before grafida/grafida#86);
#   3. a sibling PHAR behind an extra-INI block (magic fd f6 69 e6, 4-byte
#      big-endian length, ini text), with ini_get() proving it applied and a
#      file read from inside the PHAR proving the offset hooks still match;
#   4. the stub started through a symlink: phpmicro resolves itself through
#      /proc/self/exe, so the sibling is found next to the real file;
#   5. a name resolved through glibc's NSS (localhost), which is why the
#      runtime links glibc dynamically at all.

set -euo pipefail

SFX="$(realpath "$1")"
GLIBC_MAX="${GLIBC_MAX:-2.35}"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== $SFX"
file "$SFX" || true

# --- linking ---------------------------------------------------------------
readelf -l "$SFX" | grep -q 'Requesting program interpreter' \
    || fail "statically linked: expected glibc to be linked dynamically (was --enable-micro overridden?)"

needed="$(readelf -d "$SFX" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')"
echo "NEEDED: $(echo "$needed" | tr '\n' ' ')"
while read -r lib; do
    [ -n "$lib" ] || continue
    [[ "$lib" =~ ^(libc|libm|libpthread|libdl|librt|libresolv|libutil|libgcc_s)\.so\.[0-9]+$ ]] \
        || [[ "$lib" =~ ^ld-linux-(x86-64|aarch64)\.so\.[0-9]+$ ]] \
        || fail "needs $lib, which is neither glibc nor the GCC runtime"
done <<< "$needed"

newest="$(objdump -T "$SFX" | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1)"
echo "newest glibc symbol: GLIBC_$newest (max $GLIBC_MAX)"
[ "$(printf '%s\n%s\n' "$newest" "$GLIBC_MAX" | sort -V | tail -1)" = "$GLIBC_MAX" ] \
    || fail "needs GLIBC_$newest, above the $GLIBC_MAX floor"

# --- payload modes -----------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

printf '<?php echo "ok\n";' > t.php

# 1. appended
cat "$SFX" t.php > comb && chmod +x comb
[ "$(./comb)" = ok ] || fail "appended payload"
echo "ok: appended payload"
printf '<?php echo PHP_VERSION, " ", implode(",", get_loaded_extensions()), "\n";' > v.php
cat "$SFX" v.php > version && chmod +x version
echo "runtime: $(./version)"

# 2. sibling <self>.phar
cp "$SFX" t && chmod +x t && cp t.php t.phar
[ "$(./t)" = ok ] || fail "sibling <self>.phar"
echo "ok: sibling <self>.phar"

# 3. a real PHAR behind an extra-INI block
mkdir -p src
cat > src/main.php <<'PHP'
<?php
echo ini_get('memory_limit'), ' ', file_get_contents(__DIR__ . '/data.txt'), ' ', Phar::running(false) === '' ? 'no-phar' : 'phar', "\n";
PHP
printf 'payload' > src/data.txt
php -d phar.readonly=0 -r '
    $p = new Phar("w.phar");
    $p->buildFromDirectory("src");
    $p->setStub("<?php Phar::mapPhar(\"w.phar\"); require \"phar://w.phar/main.php\"; __HALT_COMPILER();");
'
php -r '
    $ini = "memory_limit=345M\n";
    file_put_contents("ini.phar", "\xfd\xf6\x69\xe6" . pack("N", strlen($ini)) . $ini . file_get_contents("w.phar"));
'
cp "$SFX" ini && chmod +x ini
out="$(./ini)"
[ "$out" = "345M payload phar" ] || fail "PHAR behind an extra-INI block: got '$out'"
echo "ok: PHAR behind an extra-INI block ($out)"

# 4. through a symlink, from another directory
mkdir -p elsewhere
ln -s "$WORK/ini" elsewhere/linked
out="$(cd / && "$WORK/elsewhere/linked")"
[ "$out" = "345M payload phar" ] || fail "symlinked stub: got '$out'"
echo "ok: stub started through a symlink"

# 5. NSS
printf '<?php echo gethostbyname("localhost"), "\n";' > nss.php
cat "$SFX" nss.php > nss && chmod +x nss
out="$(./nss)"
[ "$out" = 127.0.0.1 ] || fail "localhost resolved to '$out'"
echo "ok: localhost resolves through NSS"

echo "== all checks passed"
