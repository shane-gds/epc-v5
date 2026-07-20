"""Profile bounded identity blocking rules without materialising candidate pairs."""

from __future__ import annotations

import argparse
import time
from dataclasses import dataclass
from pathlib import Path

import duckdb


@dataclass(frozen=True)
class BlockingRule:
    name: str
    keys: str
    predicate: str


RULES = (
    BlockingRule("EXACT_UPRN", "uprn", "uprn is not null"),
    BlockingRule(
        "P01_POSTCODE_PREMISE_EXACT",
        "postcode, premise_address_comparison",
        "postcode is not null and premise_address_comparison is not null",
    ),
    BlockingRule(
        "P03_POSTCODE_NUMBER",
        "postcode, premise_number_token",
        "postcode is not null and premise_number_token is not null",
    ),
    BlockingRule(
        "P02_SECTOR_PREMISE_EXACT",
        "postcode_sector, premise_address_comparison",
        "postcode_sector is not null and premise_address_comparison is not null",
    ),
    BlockingRule(
        "EXACT_PREMISE_ADDRESS",
        "premise_address_comparison",
        "premise_address_comparison is not null",
    ),
    BlockingRule("EXACT_POSTCODE", "postcode", "postcode is not null"),
)

PROFILE_SQL = """
select
    count(*) as block_count,
    cast(sum(n * (n - 1) / 2) as ubigint) as pair_count,
    cast(sum(pp * epc) as ubigint) as cross_source_pair_count,
    cast(sum(pp * (pp - 1) / 2) as ubigint) as pp_pair_count,
    cast(sum(epc * (epc - 1) / 2) as ubigint) as epc_pair_count,
    max(n) as maximum_block_size,
    max(pp) as maximum_pp_side,
    max(epc) as maximum_epc_side,
    max(pp * epc) as maximum_cross_product,
    count(*) filter (where n > 100) as blocks_over_100,
    count(*) filter (where n > 1000) as blocks_over_1000,
    cast(coalesce(sum(pp * epc) filter (
        where pp <= 250 and epc <= 250 and pp * epc <= 10000
    ), 0) as ubigint) as admitted_cross_pairs_under_benchmark_cap,
    cast(coalesce(sum(pp * epc) filter (
        where pp > 250 or epc > 250 or pp * epc > 10000
    ), 0) as ubigint) as suppressed_cross_pairs_under_benchmark_cap
from (
    select
        {keys},
        count(*) as n,
        count(*) filter (where source_dataset = 'PPD') as pp,
        count(*) filter (where source_dataset = 'EPC_CERTIFICATE') as epc
    from identity.int_identity_observation
    where identity_run_key = (
        select identity_run_key from identity.int_identity_current_run
    )
      and is_identity_eligible
      and {predicate}
    group by {keys}
) as blocks
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--database",
        type=Path,
        default=Path("output/duckdb/epc_v5.duckdb"),
    )
    parser.add_argument("--memory-limit", default="12GB")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    connection = duckdb.connect(str(args.database), read_only=True)
    connection.execute("set memory_limit = ?", [args.memory_limit])
    headers = (
        "Rule",
        "Blocks",
        "Pairs",
        "Cross-source pairs",
        "PP pairs",
        "EPC pairs",
        "Maximum block",
        "Maximum PP side",
        "Maximum EPC side",
        "Maximum cross product",
        "Blocks >100",
        "Blocks >1000",
        "Cross pairs under cap",
        "Cross pairs suppressed",
        "Seconds",
    )
    print("| " + " | ".join(headers) + " |")
    print("|" + "|".join("---" for _ in headers) + "|")
    try:
        for rule in RULES:
            started_at = time.monotonic()
            values = connection.execute(
                PROFILE_SQL.format(keys=rule.keys, predicate=rule.predicate)
            ).fetchone()
            elapsed = time.monotonic() - started_at
            rendered = [rule.name, *(f"{value:,}" for value in values), f"{elapsed:.2f}"]
            print("| " + " | ".join(rendered) + " |")
    finally:
        connection.close()


if __name__ == "__main__":
    main()
