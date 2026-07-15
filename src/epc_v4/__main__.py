from __future__ import annotations

import argparse
import logging
from pathlib import Path

from epc_v4 import __version__
from epc_v4.import_sources import default_config_path, import_status, load_settings, run_import


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
        "--targets", nargs="+", choices=("pp", "epc", "onsud"), default=("pp", "epc", "onsud")
    )
    import_parser.add_argument("--database", type=Path)
    import_parser.add_argument("--data-root", type=Path)
    import_parser.add_argument("--log-level", default="INFO")

    status_parser = subparsers.add_parser("import-status", help="Show source import runs")
    status_parser.add_argument("--config", type=Path, default=default_config_path())
    status_parser.add_argument("--database", type=Path)

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
    else:
        print(f"epc-v4 {__version__}")


if __name__ == "__main__":
    main()
