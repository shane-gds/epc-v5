from __future__ import annotations

import argparse
import logging
from pathlib import Path

from epc_v4 import __version__
from epc_v4.import_sources import (
    default_config_path,
    import_status,
    load_settings,
    publish_silver_reconciliation,
    run_import,
)
from epc_v4.parse_identity_addresses import (
    SelectiveParseConfig,
    run_selective_address_parse,
)


def main() -> None:
    parser = argparse.ArgumentParser(prog="epc-v4")
    parser.add_argument("--version", action="version", version=f"epc-v4 {__version__}")
    subparsers = parser.add_subparsers(dest="command")

    import_parser = subparsers.add_parser(
        "import-sources", help="Load registered source files into Bronze"
    )
    import_parser.add_argument(
        "--config", type=Path, default=default_config_path(), help="Source import YAML"
    )
    import_parser.add_argument(
        "--targets",
        nargs="+",
        choices=("pp", "epc", "onsud", "lad_reference", "lpa_reference"),
        default=("pp", "epc", "onsud", "lad_reference", "lpa_reference"),
    )
    import_parser.add_argument("--database", type=Path)
    import_parser.add_argument("--data-root", type=Path)
    import_parser.add_argument("--log-level", default="INFO")

    status_parser = subparsers.add_parser("import-status", help="Show source import runs")
    status_parser.add_argument("--config", type=Path, default=default_config_path())
    status_parser.add_argument("--database", type=Path)

    publish_parser = subparsers.add_parser(
        "publish-silver-reconciliation",
        help="Publish tested Silver row counts to source manifests",
    )
    publish_parser.add_argument("--config", type=Path, default=default_config_path())
    publish_parser.add_argument("--database", type=Path)

    address_parser = subparsers.add_parser(
        "parse-identity-addresses",
        help="Parse the current selective EPC flat-trap route",
    )
    address_parser.add_argument(
        "--database", type=Path, default=Path("output/duckdb/epc_v4.duckdb")
    )
    address_parser.add_argument(
        "--library", type=Path, default=Path.home() / ".local/lib/libpostal.so"
    )
    address_parser.add_argument(
        "--data-root", type=Path, default=Path.home() / ".local/share/libpostal"
    )
    address_parser.add_argument(
        "--install-manifest",
        type=Path,
        default=Path.home() / ".local/share/epc-v4-libpostal-install.json",
    )
    address_parser.add_argument("--batch-size", type=int, default=5_000)
    address_parser.add_argument("--threads", type=int, default=1)
    address_parser.add_argument("--memory-limit", default="4GB")
    address_parser.add_argument(
        "--temp-directory", type=Path, default=Path("output/tmp/libpostal_active")
    )
    address_parser.add_argument("--log-level", default="INFO")

    args = parser.parse_args()
    if args.command == "import-sources":
        logging.basicConfig(
            level=getattr(logging, args.log_level.upper()),
            format="%(asctime)s %(levelname)s %(message)s",
        )
        run_id = run_import(
            config_path=args.config,
            targets=tuple(args.targets),
            database_path=args.database,
            data_root=args.data_root,
        )
        print(run_id)
    elif args.command == "import-status":
        settings = load_settings(args.config, database_path=args.database)
        for row in import_status(settings.database_path):
            print(" | ".join("" if value is None else str(value) for value in row))
    elif args.command == "publish-silver-reconciliation":
        settings = load_settings(args.config, database_path=args.database)
        published_count = publish_silver_reconciliation(settings.database_path)
        print(f"Published Silver reconciliation for {published_count} source files")
    elif args.command == "parse-identity-addresses":
        logging.basicConfig(
            level=getattr(logging, args.log_level.upper()),
            format="%(asctime)s %(levelname)s %(message)s",
        )
        summary = run_selective_address_parse(
            SelectiveParseConfig(
                database_path=args.database,
                library_path=args.library,
                data_root=args.data_root,
                install_manifest_path=args.install_manifest,
                batch_size=args.batch_size,
                threads=args.threads,
                memory_limit=args.memory_limit,
                temp_directory=args.temp_directory,
            )
        )
        print(summary.address_parse_run_key)
    else:
        print(f"epc-v4 {__version__}")


if __name__ == "__main__":
    main()
