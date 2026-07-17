"""Pinned libpostal runtime loading and artifact provenance."""

from __future__ import annotations

import ctypes
import hashlib
import importlib.util
import json
from collections.abc import Callable
from pathlib import Path
from typing import Any

LIBPOSTAL_COMMIT = "25099c506612b34b23b1bfe286ca6321fcf06f35"
PYPPOSTAL_COMMIT = "d6666a4f6a2ae0e7b83e037a35412f0f6b45c318"
INSTALL_MANIFEST_CONTRACT_VERSION = "epc_v4_libpostal_install_v1"


def file_sha256(path: Path) -> str:
    """Hash one file without loading it into memory."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _add_framed_bytes(digest: Any, value: bytes) -> None:
    digest.update(len(value).to_bytes(8, byteorder="big", signed=False))
    digest.update(value)


def fingerprint_directory(path: Path) -> tuple[str, int]:
    """Hash relative paths, sizes, and contents for all files under a directory."""
    digest = hashlib.sha256()
    total_size = 0
    for file_path in sorted(candidate for candidate in path.rglob("*") if candidate.is_file()):
        relative_path = file_path.relative_to(path).as_posix().encode()
        _add_framed_bytes(digest, relative_path)
        digest.update(file_path.stat().st_size.to_bytes(8, byteorder="big", signed=False))
        with file_path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                total_size += len(chunk)
                digest.update(chunk)
    return digest.hexdigest(), total_size


def fingerprint_files(paths: list[Path], root: Path) -> str:
    """Hash a declared implementation file set with framed relative paths."""
    digest = hashlib.sha256()
    for path in sorted(paths):
        _add_framed_bytes(digest, path.relative_to(root).as_posix().encode())
        digest.update(path.stat().st_size.to_bytes(8, byteorder="big", signed=False))
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
    return digest.hexdigest()


def installed_artifact_evidence(library_path: Path, data_root: Path) -> dict[str, Any]:
    """Fingerprint the native library, Python extension, and model data."""
    resolved_library = library_path.resolve(strict=True)
    postal_spec = importlib.util.find_spec("postal")
    if postal_spec is None or not postal_spec.submodule_search_locations:
        raise RuntimeError("Python package 'postal' is not installed")
    postal_root = Path(next(iter(postal_spec.submodule_search_locations)))
    extension_files = sorted(postal_root.glob("*.so"))
    if not extension_files:
        raise RuntimeError(f"No pypostal extension files found under {postal_root}")
    model_sha256, model_size = fingerprint_directory(data_root)
    return {
        "libpostal_library_path": str(resolved_library),
        "libpostal_library_sha256": file_sha256(resolved_library),
        "pypostal_extension_root": str(postal_root),
        "pypostal_extension_file_count": len(extension_files),
        "pypostal_extensions_sha256": fingerprint_files(extension_files, postal_root),
        "libpostal_model_data_sha256": model_sha256,
        "libpostal_model_data_bytes": model_size,
    }


def verify_install_manifest(
    manifest_path: Path,
    actual: dict[str, Any],
    libpostal_commit: str = LIBPOSTAL_COMMIT,
    pypostal_commit: str = PYPPOSTAL_COMMIT,
    model_variant: str = "default",
) -> dict[str, Any]:
    """Fail if installed runtime bytes differ from their pinned manifest."""
    if not manifest_path.is_file():
        raise FileNotFoundError(
            f"Pinned libpostal install manifest not found: {manifest_path}; "
            "run make libpostal-setup"
        )
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected = {
        "manifest_contract_version": INSTALL_MANIFEST_CONTRACT_VERSION,
        "libpostal_commit": libpostal_commit,
        "pypostal_commit": pypostal_commit,
        "model_variant": model_variant,
        "libpostal_library_sha256": actual["libpostal_library_sha256"],
        "pypostal_extensions_sha256": actual["pypostal_extensions_sha256"],
        "libpostal_model_data_sha256": actual["libpostal_model_data_sha256"],
    }
    mismatches = {
        key: {"manifest": manifest.get(key), "actual": value}
        for key, value in expected.items()
        if manifest.get(key) != value
    }
    if mismatches:
        raise RuntimeError(
            f"Installed libpostal artifacts do not match their manifest: {mismatches}"
        )
    return manifest


def load_libpostal_parser(library_path: Path) -> Callable[[str], list[tuple[str, str]]]:
    """Load the pinned native library before importing the pypostal extension."""
    if not library_path.is_file():
        raise FileNotFoundError(f"libpostal shared library not found: {library_path}")
    ctypes.CDLL(str(library_path), mode=ctypes.RTLD_GLOBAL)
    try:
        from postal.parser import parse_address
    except ImportError as error:
        raise RuntimeError(
            "Python package 'postal' is not installed; run make libpostal-setup"
        ) from error
    return parse_address
