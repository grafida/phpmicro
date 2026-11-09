#!/usr/bin/env bash
#
# Check a macOS micro.sfx before it is published or pinned: what it is built
# for, how it is linked, and that every payload mode the consumers rely on works
# (grafida/grafida#88).
#
#   .github/scripts/check-macos-sfx.sh path/to/micro.sfx
#
# Environment:
#   EXPECT_ARCH  the one architecture the file must contain (default: arm64)
#   MACOS_MIN    the highest acceptable minimum macOS version (default: 12.0,
#                the floor of the Grafida shell; ADR 0001)
#
# Needs a `php` with the phar extension on PATH (to build the test PHAR) and
# the Command Line Tools (otool, lipo, codesign). Runs in a throwaway directory.
# Nothing here needs a signing identity: every signature is ad hoc.
#
# Build: a thin Mach-O of EXPECT_ARCH whose LC_BUILD_VERSION minos is at most
# MACOS_MIN. The floor is read from the binary, not assumed, because the
# runner's SDK decides it when nobody sets MACOSX_DEPLOYMENT_TARGET, and a
# runner image change once raised an app's floor silently (Grafida gh-58).
#
# Linking: static, apart from the OS itself (/usr/lib and /System/Library).
# A Homebrew or MacPorts library would load on the build machine and nowhere
# else.
#
# Payload modes:
#   1. appended payload (stock phpmicro behaviour; regression);
#   2. sibling "<self>.phar";
#   3. the app-bundle layout: the stub in Contents/MacOS, and a real PHAR behind
#      an extra-INI block (magic fd f6 69 e6, 4-byte big-endian length, ini
#      text) in Contents/Resources/<basename>.phar, with ini_get() proving the
#      block applied and a file read from inside the PHAR proving the offset
#      hooks still match the realpath()'d "../Resources" candidate;
#   4. that stub started through a symlink from another directory: phpmicro
#      realpath()s its own path, so the sibling is found next to the real file;
#   5. that stub signed ad hoc, and then signed ad hoc with the hardened runtime
#      and NO entitlements: a signature covers the stub only, so the sibling must
#      still load; and the worker should need no entitlement at all;
#   6. a name resolved by the system resolver (localhost).

set -euo pipefail

SFX="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
EXPECT_ARCH="${EXPECT_ARCH:-arm64}"
MACOS_MIN="${MACOS_MIN:-12.0}"

fail() { echo "FAIL: $*" >&2; exit 1; }

# a <= b, for dotted versions
version_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$1" ]; }

echo "== $SFX"
file "$SFX" || true
shasum -a 256 "$SFX"

# --- build -----------------------------------------------------------------
archs="$(lipo -archs "$SFX")"
echo "architectures: $archs"
[ "$archs" = "$EXPECT_ARCH" ] || fail "expected a thin $EXPECT_ARCH Mach-O, got '$archs'"

minos="$(otool -l "$SFX" | awk '$1 == "cmd" { cmd = $2 } cmd == "LC_BUILD_VERSION" && $1 == "minos" { print $2; exit }')"
sdk="$(otool -l "$SFX" | awk '$1 == "cmd" { cmd = $2 } cmd == "LC_BUILD_VERSION" && $1 == "sdk" { print $2; exit }')"
[ -n "$minos" ] || fail "no LC_BUILD_VERSION minos"
echo "minos $minos (max $MACOS_MIN), sdk $sdk"
version_le "$minos" "$MACOS_MIN" || fail "minimum macOS $minos is above the $MACOS_MIN floor"

# --- linking ---------------------------------------------------------------
libs="$(otool -L "$SFX" | tail -n +2 | awk '{ print $1 }')"
echo "linked: $(echo "$libs" | tr '\n' ' ')"
while read -r lib; do
    [ -n "$lib" ] || continue
    case "$lib" in
        /usr/lib/*|/System/Library/*) ;;
        *) fail "links $lib, which is not part of macOS" ;;
    esac
done <<< "$libs"

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

# 3. the bundle layout, with a real PHAR behind an extra-INI block
mkdir -p src
cat > src/main.php <<'PHP'
<?php
echo ini_get('memory_limit'), ' ', file_get_contents(__DIR__ . '/data.txt'), ' ', Phar::running(false) === '' ? 'no-phar' : 'phar', "\n";
PHP
printf 'payload' > src/data.txt
# shellcheck disable=SC2016 # PHP code, not shell: nothing should expand
php -d phar.readonly=0 -r '
    $p = new Phar("w.phar");
    $p->buildFromDirectory("src");
    $p->setStub("<?php Phar::mapPhar(\"w.phar\"); require \"phar://w.phar/main.php\"; __HALT_COMPILER();");
'
mkdir -p App.app/Contents/MacOS App.app/Contents/Resources
# shellcheck disable=SC2016 # PHP code, not shell
php -r '
    $ini = "memory_limit=345M\n";
    file_put_contents("App.app/Contents/Resources/worker.phar", "\xfd\xf6\x69\xe6" . pack("N", strlen($ini)) . $ini . file_get_contents("w.phar"));
'
cp "$SFX" App.app/Contents/MacOS/worker && chmod +x App.app/Contents/MacOS/worker
expected="345M payload phar"
out="$(App.app/Contents/MacOS/worker)"
[ "$out" = "$expected" ] || fail "bundle layout, PHAR behind an extra-INI block: got '$out'"
echo "ok: ../Resources/<basename>.phar behind an extra-INI block ($out)"

# 4. through a symlink, from another directory
mkdir -p elsewhere
ln -s "$WORK/App.app/Contents/MacOS/worker" elsewhere/linked
out="$(cd / && "$WORK/elsewhere/linked")"
[ "$out" = "$expected" ] || fail "symlinked stub: got '$out'"
echo "ok: stub started through a symlink"

# 5. signed ad hoc; then ad hoc with the hardened runtime and no entitlements
codesign --force --sign - App.app/Contents/MacOS/worker
codesign --verify --strict App.app/Contents/MacOS/worker || fail "the ad-hoc signature does not verify"
out="$(App.app/Contents/MacOS/worker)"
[ "$out" = "$expected" ] || fail "ad-hoc-signed stub: got '$out'"
echo "ok: ad-hoc-signed stub loads its sibling"
codesign --force --sign - --options runtime App.app/Contents/MacOS/worker
# Captured first: `grep -q` stops reading at the first match, and under
# pipefail the writer's SIGPIPE would fail the check.
signature="$(codesign --display --verbose=2 App.app/Contents/MacOS/worker 2>&1)"
[[ "$signature" =~ flags=0x[0-9a-f]+\([a-z,-]*runtime ]] || fail "the hardened-runtime flag did not stick"
out="$(App.app/Contents/MacOS/worker)"
[ "$out" = "$expected" ] || fail "hardened-runtime stub with no entitlements: got '$out'"
echo "ok: hardened runtime, no entitlements: the stub loads its sibling"

# 6. the system resolver
printf '<?php echo gethostbyname("localhost"), "\n";' > dns.php
cat "$SFX" dns.php > dns && chmod +x dns
out="$(./dns)"
[ "$out" = 127.0.0.1 ] || fail "localhost resolved to '$out'"
echo "ok: localhost resolves"

echo "== all checks passed"
