"""Profile supplied EPC UPRN groups before deterministic identity decisions."""

from __future__ import annotations

import argparse
from pathlib import Path

import duckdb


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--database",
        type=Path,
        default=Path("output/duckdb/epc_v4.duckdb"),
    )
    return parser.parse_args()


SUMMARY_SQL = """
with observations as (
    select uprn, premise_address_comparison, postcode, property_type
    from identity.int_identity_observation
    where identity_run_key = (
        select identity_run_key from identity.int_identity_current_run
    )
      and source_dataset = 'EPC_CERTIFICATE'
      and uprn is not null
),
groups as (
    select
        uprn,
        count(*) as observation_count,
        count(distinct premise_address_comparison) as address_count,
        count(distinct postcode) as postcode_count,
        count(distinct property_type) as property_type_count
    from observations
    group by uprn
),
address_pairs as (
    select uprn, sum(n * (n - 1) / 2) as exact_address_pairs
    from (
        select uprn, premise_address_comparison, count(*) as n
        from observations
        group by uprn, premise_address_comparison
    ) as address_groups
    group by uprn
)
select
    count(*) as uprn_groups,
    sum(observation_count) as observations,
    max(observation_count) as maximum_group_size,
    count(*) filter (where address_count > 1) as groups_with_multiple_addresses,
    count(*) filter (where postcode_count > 1) as groups_with_multiple_postcodes,
    count(*) filter (where property_type_count > 1) as groups_with_multiple_property_types,
    cast(sum(observation_count * (observation_count - 1) / 2) as ubigint) as all_pairs,
    cast(sum(exact_address_pairs) as ubigint) as exact_address_pairs,
    cast(
        sum(observation_count * (observation_count - 1) / 2 - exact_address_pairs)
        as ubigint
    ) as discordant_address_pairs
from groups
inner join address_pairs using (uprn)
"""

TOP_GROUPS_SQL = """
select
    uprn,
    count(*) as observation_count,
    count(distinct premise_address_comparison) as address_count,
    count(distinct postcode) as postcode_count,
    count(distinct property_type) as property_type_count
from identity.int_identity_observation
where identity_run_key = (
    select identity_run_key from identity.int_identity_current_run
)
  and source_dataset = 'EPC_CERTIFICATE'
  and uprn is not null
group by uprn
order by observation_count desc, uprn
limit 20
"""


def main() -> None:
    args = parse_args()
    connection = duckdb.connect(str(args.database), read_only=True)
    try:
        headers = [description[0] for description in connection.execute(SUMMARY_SQL).description]
        values = connection.fetchone()
        print("| " + " | ".join(headers) + " |")
        print("|" + "|".join("---" for _ in headers) + "|")
        print("| " + " | ".join(f"{value:,}" for value in values) + " |")
        print()
        print("Largest supplied UPRN groups:")
        print()
        print("| UPRN | Observations | Addresses | Postcodes | Property types |")
        print("|---|---:|---:|---:|---:|")
        for row in connection.execute(TOP_GROUPS_SQL).fetchall():
            print("| " + " | ".join(str(value) for value in row) + " |")
    finally:
        connection.close()


if __name__ == "__main__":
    main()
