#!/usr/bin/env bash
# Runs OffloadPro's pure-logic unit suite on Linux without Xcode.
# Builds a local SQLite with SQLITE_ENABLE_SNAPSHOT (required by GRDB 6.x
# on Linux) into /tmp/sqlite-custom, then invokes `swift test`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SQLITE_PREFIX="${SQLITE_PREFIX:-/tmp/sqlite-custom}"
SWIFT_BIN="${SWIFT_BIN:-swift}"

need_sqlite_build() {
  if [[ ! -f "$SQLITE_PREFIX/lib/libsqlite3.so" ]]; then
    return 0
  fi
  if ! nm -D "$SQLITE_PREFIX/lib/libsqlite3.so" 2>/dev/null | grep -q 'sqlite3_snapshot_open'; then
    return 0
  fi
  return 1
}

if need_sqlite_build; then
  echo "==> Building SQLite with SQLITE_ENABLE_SNAPSHOT into $SQLITE_PREFIX"
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  curl -fsSL https://www.sqlite.org/2024/sqlite-autoconf-3450100.tar.gz -o "$WORK/sqlite.tar.gz"
  tar -xzf "$WORK/sqlite.tar.gz" -C "$WORK"
  pushd "$WORK/sqlite-autoconf-3450100" >/dev/null
  ./configure --prefix="$SQLITE_PREFIX" \
    CFLAGS="-O2 -DSQLITE_ENABLE_SNAPSHOT -DSQLITE_ENABLE_FTS5 -DSQLITE_THREADSAFE=1" \
    >/dev/null
  make -j"$(nproc)" >/dev/null
  make install >/dev/null
  popd >/dev/null
fi

export LIBRARY_PATH="$SQLITE_PREFIX/lib:${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="$SQLITE_PREFIX/lib:${LD_LIBRARY_PATH:-}"
export CPATH="$SQLITE_PREFIX/include:${CPATH:-}"
export PKG_CONFIG_PATH="$SQLITE_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

cd "$ROOT"
echo "==> swift test"
exec "$SWIFT_BIN" test \
  -Xlinker -L"$SQLITE_PREFIX/lib" \
  -Xlinker -lsqlite3 \
  -Xlinker -rpath \
  -Xlinker "$SQLITE_PREFIX/lib" \
  -Xcc -I"$SQLITE_PREFIX/include" \
  "$@"
