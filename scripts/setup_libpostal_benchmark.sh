#!/usr/bin/env bash
set -euo pipefail

LIBPOSTAL_COMMIT="${LIBPOSTAL_COMMIT:-25099c506612b34b23b1bfe286ca6321fcf06f35}"
PYPPOSTAL_COMMIT="${PYPPOSTAL_COMMIT:-d6666a4f6a2ae0e7b83e037a35412f0f6b45c318}"
PREFIX="${LIBPOSTAL_PREFIX:-$HOME/.local}"
BUILD_ROOT="${LIBPOSTAL_BUILD_ROOT:-/tmp/libpostal-${LIBPOSTAL_COMMIT:0:7}}"
PYTHON="${PYTHON:-.venv/bin/python}"

for command in git autoconf automake libtoolize pkg-config make gcc curl; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Missing build prerequisite: %s\n' "$command" >&2
    exit 1
  fi
done

INSTALL_MANIFEST="$PREFIX/share/epc-v5-libpostal-install.json"
if [ -f "$INSTALL_MANIFEST" ]; then
  LIBPOSTAL_COMMIT="$LIBPOSTAL_COMMIT" \
  PYPPOSTAL_COMMIT="$PYPPOSTAL_COMMIT" \
  LIBPOSTAL_PREFIX="$PREFIX" \
    "$PYTHON" - <<'PY'
import os
from pathlib import Path

from epc_v5.libpostal_runtime import (
    installed_artifact_evidence,
    verify_install_manifest,
)

prefix = Path(os.environ["LIBPOSTAL_PREFIX"])
manifest_path = prefix / "share/epc-v5-libpostal-install.json"
actual = installed_artifact_evidence(
    prefix / "lib/libpostal.so",
    prefix / "share/libpostal",
)
verify_install_manifest(
    manifest_path,
    actual,
    os.environ["LIBPOSTAL_COMMIT"],
    os.environ["PYPPOSTAL_COMMIT"],
    "default",
)
print(f"Verified existing pinned install: {manifest_path}")
PY
  exit 0
fi

if [ ! -d "$BUILD_ROOT/.git" ]; then
  git clone https://github.com/openvenues/libpostal.git "$BUILD_ROOT"
elif [ -n "$(git -C "$BUILD_ROOT" status --porcelain)" ]; then
  printf 'Build root is not clean; choose a new LIBPOSTAL_BUILD_ROOT: %s\n' "$BUILD_ROOT" >&2
  exit 1
fi

git -C "$BUILD_ROOT" fetch --quiet origin "$LIBPOSTAL_COMMIT"
git -C "$BUILD_ROOT" checkout --detach "$LIBPOSTAL_COMMIT"

if [ "$(git -C "$BUILD_ROOT" rev-parse HEAD)" != "$LIBPOSTAL_COMMIT" ]; then
  printf 'libpostal checkout does not match requested commit\n' >&2
  exit 1
fi

(
  cd "$BUILD_ROOT"
  ./bootstrap.sh
  ./configure --prefix="$PREFIX" --datadir="$PREFIX/share"
  make -j"${LIBPOSTAL_BUILD_JOBS:-2}"
  make install
)

PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
LDFLAGS="-Wl,-rpath,$PREFIX/lib ${LDFLAGS:-}" \
  "$PYTHON" -m pip install \
    "git+https://github.com/openvenues/pypostal.git@$PYPPOSTAL_COMMIT"

LIBPOSTAL_COMMIT="$LIBPOSTAL_COMMIT" \
PYPPOSTAL_COMMIT="$PYPPOSTAL_COMMIT" \
LIBPOSTAL_PREFIX="$PREFIX" \
  "$PYTHON" - <<'PY'
import json
import os
import platform
import subprocess
from datetime import UTC, datetime
from pathlib import Path

from epc_v5.libpostal_runtime import installed_artifact_evidence

prefix = Path(os.environ["LIBPOSTAL_PREFIX"])
evidence = installed_artifact_evidence(
    prefix / "lib/libpostal.so",
    prefix / "share/libpostal",
)
manifest = {
    **evidence,
    "manifest_contract_version": "epc_v5_libpostal_install_v1",
    "installed_at": datetime.now(UTC).isoformat(),
    "libpostal_commit": os.environ["LIBPOSTAL_COMMIT"],
    "pypostal_commit": os.environ["PYPPOSTAL_COMMIT"],
    "model_variant": "default",
    "platform": platform.platform(),
    "python_version": platform.python_version(),
    "gcc_version": subprocess.run(
        ["gcc", "--version"], check=True, capture_output=True, text=True
    ).stdout.splitlines()[0],
    "configure_arguments": [
        f"--prefix={prefix}",
        f"--datadir={prefix / 'share'}",
    ],
}
manifest_path = prefix / "share/epc-v5-libpostal-install.json"
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
print(manifest_path)
PY

printf 'Installed libpostal %s and pypostal %s under %s\n' \
  "$LIBPOSTAL_COMMIT" "$PYPPOSTAL_COMMIT" "$PREFIX"
