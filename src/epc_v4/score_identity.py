"""Train and benchmark the versioned Splink identity comparison model."""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import duckdb
import splink
import splink.comparison_level_library as cll
import splink.comparison_library as cl
from splink import Linker, SettingsCreator
from splink.backends.duckdb import DuckDBAPI
from splink.blocking_rule_library import CustomRule

from epc_v4.stable_keys import sql_literal, stable_sha256_sql

LOGGER = logging.getLogger(__name__)

D01_SQL = (
    "l.source_dataset = 'EPC_CERTIFICATE' "
    "and r.source_dataset = 'EPC_CERTIFICATE' "
    "and l.uprn = r.uprn and l.uprn is not null"
)
P01_SQL = (
    "l.source_dataset <> r.source_dataset "
    "and l.postcode = r.postcode "
    "and l.premise_address_comparison = r.premise_address_comparison"
)
P02_SQL = (
    "l.source_dataset <> r.source_dataset "
    "and l.postcode_sector = r.postcode_sector "
    "and l.premise_address_comparison = r.premise_address_comparison "
    "and l.postcode <> r.postcode"
)
P04_SQL = (
    "l.postcode = r.postcode "
    "and l.unit_identifier_comparison = r.unit_identifier_comparison "
    "and l.building_number_designator = r.building_number_designator "
    "and l.premise_address_comparison <> r.premise_address_comparison "
    "and l.address_component_status = 'COMPLETE' "
    "and r.address_component_status = 'COMPLETE' "
    "and l.libpostal_candidate_block_status = 'ADMITTED' "
    "and r.libpostal_candidate_block_status = 'ADMITTED' "
    "and ((l.source_dataset = 'PPD' "
    "and l.address_component_method = 'PPD_STRUCTURED_FIELDS' "
    "and r.source_dataset = 'EPC_CERTIFICATE' "
    "and r.address_component_method = 'LIBPOSTAL' "
    "and contains(concat(' ', r.road_comparison, ' '), "
    "concat(' ', l.road_comparison, ' '))) "
    "or (r.source_dataset = 'PPD' "
    "and r.address_component_method = 'PPD_STRUCTURED_FIELDS' "
    "and l.source_dataset = 'EPC_CERTIFICATE' "
    "and l.address_component_method = 'LIBPOSTAL' "
    "and contains(concat(' ', l.road_comparison, ' '), "
    "concat(' ', r.road_comparison, ' '))))"
)


def _now() -> datetime:
    return datetime.now(UTC)


def create_settings(*, salting_partitions: int, linker_uid: str) -> SettingsCreator:
    """Return the uncalibrated benchmark comparison contract."""
    uprn_comparison = cl.CustomComparison(
        output_column_name="uprn",
        comparison_description="Supplied EPC UPRN agreement",
        comparison_levels=[
            cll.NullLevel("uprn"),
            cll.ExactMatchLevel("uprn").configure(
                m_probability=0.999,
                u_probability=0.000001,
                fix_m_probability=True,
                fix_u_probability=True,
                label_for_charts="Exact supplied UPRN",
            ),
            cll.ElseLevel().configure(
                m_probability=0.001,
                u_probability=0.999999,
                fix_m_probability=True,
                fix_u_probability=True,
                label_for_charts="Different supplied UPRN",
            ),
        ],
    )
    postcode_comparison = cl.CustomComparison(
        output_column_name="postcode",
        comparison_description="Postcode and sector agreement",
        comparison_levels=[
            cll.NullLevel("postcode"),
            cll.ExactMatchLevel("postcode", term_frequency_adjustments=True),
            cll.ExactMatchLevel("postcode_sector").configure(
                label_for_charts="Exact postcode sector"
            ),
            cll.ElseLevel(),
        ],
    )
    address_comparison = cl.CustomComparison(
        output_column_name="premise_address",
        comparison_description="Source-neutral premise address similarity",
        comparison_levels=[
            cll.NullLevel("premise_address_comparison"),
            cll.ExactMatchLevel("premise_address_comparison", term_frequency_adjustments=True),
            cll.JaroWinklerLevel("premise_address_comparison", 0.95),
            cll.JaroWinklerLevel("premise_address_comparison", 0.88),
            cll.ElseLevel(),
        ],
    )
    return SettingsCreator(
        link_type="dedupe_only",
        unique_id_column_name="unique_id",
        source_dataset_column_name="source_dataset",
        comparisons=[
            uprn_comparison,
            postcode_comparison,
            address_comparison,
            cl.ExactMatch("premise_number_token"),
            cl.ExactMatch("property_class"),
        ],
        blocking_rules_to_generate_predictions=[
            CustomRule(D01_SQL, salting_partitions=salting_partitions),
            CustomRule(P01_SQL, salting_partitions=salting_partitions),
            CustomRule(P02_SQL, salting_partitions=salting_partitions),
            CustomRule(P04_SQL, salting_partitions=salting_partitions),
        ],
        probability_two_random_records_match=0.000001,
        retain_matching_columns=False,
        retain_intermediate_calculation_columns=True,
        additional_columns_to_retain=["identity_observation_key"],
        max_iterations=15,
        em_convergence=0.0001,
        linker_uid=linker_uid,
    )


def _create_audit_table(connection: duckdb.DuckDBPyConnection) -> None:
    connection.execute(
        """
        create table if not exists identity.identity_splink_run (
            splink_run_id uuid primary key,
            identity_run_id uuid not null,
            identity_run_key varchar not null,
            run_mode varchar not null,
            model_version varchar not null,
            model_status varchar not null,
            splink_version varchar not null,
            duckdb_version varchar not null,
            settings_json json not null,
            training_sample_predicate varchar,
            started_at timestamptz not null,
            completed_at timestamptz,
            run_status varchar not null,
            training_record_count ubigint,
            expected_candidate_count ubigint,
            scored_candidate_count ubigint,
            model_path varchar,
            model_sha256 varchar,
            failure_message varchar
        )
        """
    )
    connection.execute(
        """
        create table if not exists identity.identity_splink_publication (
            identity_run_key varchar primary key,
            splink_run_id uuid not null unique,
            model_sha256 varchar not null,
            published_at timestamptz not null
        )
        """
    )
    connection.execute(
        """
        create table if not exists identity.identity_splink_publication_event (
            publication_event_id uuid primary key,
            identity_run_key varchar not null,
            splink_run_id uuid not null,
            model_sha256 varchar not null,
            published_at timestamptz not null
        )
        """
    )


def _current_identity_run(connection: duckdb.DuckDBPyConnection) -> tuple[Any, ...]:
    row = connection.execute(
        """
        select identity_run_id, identity_run_key, comparison_model_version
        from identity.int_identity_current_run
        """
    ).fetchone()
    if row is None:
        raise RuntimeError("Current identity run is not materialised")
    return row


def _settings_json(settings: SettingsCreator) -> str:
    return json.dumps(settings.get_settings("duckdb").as_dict(), sort_keys=True)


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("benchmark", "national"), default="benchmark")
    parser.add_argument(
        "--database",
        type=Path,
        default=Path("output/duckdb/epc_v4.duckdb"),
    )
    parser.add_argument("--output-root", type=Path, default=Path("output/identity"))
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--memory-limit", default="12GB")
    parser.add_argument("--salting-partitions", type=int, default=4)
    parser.add_argument("--sample-hex-max", default="03")
    parser.add_argument("--u-pairs", type=int, default=1_000_000)
    parser.add_argument("--model-path", type=Path)
    parser.add_argument("--log-level", default="INFO")
    return parser.parse_args()


def _create_match_score_table(connection: duckdb.DuckDBPyConnection) -> None:
    connection.execute(
        """
        create table if not exists identity.identity_match_score (
            match_score_key varchar not null,
            candidate_pair_key varchar not null,
            identity_run_id uuid not null,
            identity_run_key varchar not null,
            splink_run_id uuid not null,
            model_version varchar not null,
            model_sha256 varchar not null,
            model_status varchar not null,
            match_weight double not null,
            match_probability double not null,
            splink_match_key varchar not null,
            primary_blocking_rule_code varchar not null,
            uprn_comparison_level varchar not null,
            postcode_comparison_level varchar not null,
            premise_address_comparison_level varchar not null,
            premise_number_comparison_level varchar not null,
            property_class_comparison_level varchar not null,
            bf_uprn double,
            bf_postcode double,
            bf_tf_adj_postcode double,
            bf_premise_address double,
            bf_tf_adj_premise_address double,
            bf_premise_number_token double,
            bf_property_class double,
            score_components json not null,
            scored_at timestamptz not null
        )
        """
    )


def initialize_registry_tables(connection: duckdb.DuckDBPyConnection) -> None:
    """Create persistent registry foundations without allocating any entities."""
    connection.execute("create schema if not exists core")
    connection.execute(
        """
        create table if not exists core.registry_entity (
            registry_entity_id uuid primary key,
            entity_kind varchar not null,
            registry_status varchar not null,
            created_by_identity_run_id uuid not null,
            promotion_decision_key varchar not null,
            created_at timestamptz not null,
            retired_at timestamptz
        )
        """
    )
    connection.execute(
        """
        create table if not exists core.registry_identifier (
            registry_identifier_id uuid primary key,
            registry_entity_id uuid not null,
            identifier_type varchar not null,
            identifier_value varchar not null,
            identifier_status varchar not null,
            valid_from date,
            valid_to date,
            created_at timestamptz not null
        )
        """
    )
    connection.execute(
        """
        create table if not exists core.bridge_registry_observation (
            registry_entity_id uuid not null,
            identity_run_id uuid not null,
            identity_run_observation_key varchar not null,
            promotion_decision_key varchar not null,
            link_status varchar not null,
            linked_at timestamptz not null
        )
        """
    )


def run_national(args: argparse.Namespace) -> uuid.UUID:
    """Score every contracted candidate with an approved benchmark model artifact."""
    if args.model_path is None or not args.model_path.is_file():
        raise ValueError("--model-path must identify a successful benchmark model JSON")

    model_path = args.model_path.resolve()
    model_sha256 = _sha256_file(model_path)
    model_json = model_path.read_text(encoding="utf-8")
    connection = duckdb.connect(str(args.database))
    connection.execute(f"set threads = {args.threads}")
    connection.execute("set memory_limit = ?", [args.memory_limit])
    connection.execute("set preserve_insertion_order = false")
    _create_audit_table(connection)
    _create_match_score_table(connection)
    initialize_registry_tables(connection)

    identity_run_id, identity_run_key, model_version = _current_identity_run(connection)
    existing_publication = connection.execute(
        """
        select splink_run_id, model_sha256
        from identity.identity_splink_publication
        where identity_run_key = ?
        """,
        [identity_run_key],
    ).fetchone()
    if existing_publication is not None:
        raise RuntimeError(
            "The current identity run already has an immutable national Splink publication; "
            "change the comparison-model version to publish another artifact"
        )
    benchmark = connection.execute(
        """
        select splink_run_id
        from identity.identity_splink_run
        where identity_run_key = ?
          and run_mode = 'BENCHMARK'
          and run_status = 'SUCCEEDED'
          and model_version = ?
          and model_sha256 = ?
        order by completed_at desc
        limit 1
        """,
        [identity_run_key, model_version, model_sha256],
    ).fetchone()
    if benchmark is None:
        raise RuntimeError("Model artifact is not registered to a successful current-run benchmark")

    existing_score_count = connection.execute(
        """
        select count(*)
        from identity.identity_match_score
        where identity_run_key = ? and model_sha256 = ?
        """,
        [identity_run_key, model_sha256],
    ).fetchone()[0]
    if existing_score_count:
        raise RuntimeError(
            f"Current run/model already has {existing_score_count:,} persisted scores"
        )

    splink_run_id = uuid.uuid4()
    connection.execute(
        """
        insert into identity.identity_splink_run (
            splink_run_id, identity_run_id, identity_run_key, run_mode,
            model_version, model_status, splink_version, duckdb_version,
            settings_json, started_at, run_status, model_path, model_sha256
        ) values (?, ?, ?, 'NATIONAL', ?, 'UNCALIBRATED', ?, ?, ?, ?, 'RUNNING', ?, ?)
        """,
        [
            splink_run_id,
            identity_run_id,
            identity_run_key,
            model_version,
            splink.__version__,
            duckdb.__version__,
            model_json,
            _now(),
            str(model_path),
            model_sha256,
        ],
    )

    try:
        expected_count = connection.execute(
            """
            select count(*)
            from identity.identity_candidate_pair
            where identity_run_key = ?
            """,
            [identity_run_key],
        ).fetchone()[0]
        connection.execute("set schema = 'identity'")
        linker = Linker(
            "identity_scoring_input",
            str(model_path),
            db_api=DuckDBAPI(connection=connection),
        )
        LOGGER.info("Scoring %s contracted national candidates", f"{expected_count:,}")
        predictions = linker.inference.predict(
            threshold_match_probability=None,
            materialise_after_computing_term_frequencies=True,
            materialise_blocked_pairs=True,
        )
        prediction_table = predictions.physical_name
        scored_count = connection.execute(f"select count(*) from {prediction_table}").fetchone()[0]
        if scored_count != expected_count:
            raise RuntimeError(
                "National Splink candidate closure failed before publication: "
                f"expected {expected_count:,}, scored {scored_count:,}"
            )

        score_key_sql = stable_sha256_sql(
            "epc-v4.identity.match-score",
            "v1",
            [
                "candidate.candidate_pair_key",
                sql_literal(model_version),
                sql_literal(model_sha256),
            ],
        )
        scored_at = _now().isoformat()
        insert_sql = f"""
            insert into identity.identity_match_score
            with prediction as (
                select
                    *,
                    least(unique_id_l, unique_id_r) as canonical_id_l,
                    greatest(unique_id_l, unique_id_r) as canonical_id_r
                from {prediction_table}
            )
            select
                {score_key_sql} as match_score_key,
                candidate.candidate_pair_key,
                candidate.identity_run_id,
                candidate.identity_run_key,
                uuid {sql_literal(str(splink_run_id))} as splink_run_id,
                {sql_literal(model_version)} as model_version,
                {sql_literal(model_sha256)} as model_sha256,
                'UNCALIBRATED' as model_status,
                prediction.match_weight,
                prediction.match_probability,
                prediction.match_key as splink_match_key,
                candidate.primary_blocking_rule_code,
                case
                    when left_input.uprn is null or right_input.uprn is null then 'MISSING'
                    when left_input.uprn = right_input.uprn then 'EXACT'
                    else 'DIFFERENT'
                end as uprn_comparison_level,
                case
                    when left_input.postcode is null or right_input.postcode is null then 'MISSING'
                    when left_input.postcode = right_input.postcode then 'EXACT'
                    when left_input.postcode_sector = right_input.postcode_sector
                        then 'SECTOR_EXACT'
                    else 'DIFFERENT'
                end as postcode_comparison_level,
                case
                    when left_input.premise_address_comparison is null
                      or right_input.premise_address_comparison is null then 'MISSING'
                    when left_input.premise_address_comparison
                       = right_input.premise_address_comparison then 'EXACT'
                    when jaro_winkler_similarity(
                        left_input.premise_address_comparison,
                        right_input.premise_address_comparison
                    ) >= 0.95 then 'JARO_WINKLER_GE_0_95'
                    when jaro_winkler_similarity(
                        left_input.premise_address_comparison,
                        right_input.premise_address_comparison
                    ) >= 0.88 then 'JARO_WINKLER_GE_0_88'
                    else 'OTHER'
                end as premise_address_comparison_level,
                case
                    when left_input.premise_number_token is null
                      or right_input.premise_number_token is null then 'MISSING'
                    when left_input.premise_number_token = right_input.premise_number_token
                        then 'EXACT'
                    else 'DIFFERENT'
                end as premise_number_comparison_level,
                case
                    when left_input.property_class is null or right_input.property_class is null
                        then 'MISSING'
                    when left_input.property_class = right_input.property_class then 'EXACT'
                    else 'DIFFERENT'
                end as property_class_comparison_level,
                prediction.bf_uprn,
                prediction.bf_postcode,
                prediction.bf_tf_adj_postcode,
                prediction.bf_premise_address,
                prediction.bf_tf_adj_premise_address,
                prediction.bf_premise_number_token,
                prediction.bf_property_class,
                json_object(
                    'bf_uprn', prediction.bf_uprn,
                    'bf_postcode', prediction.bf_postcode,
                    'bf_tf_adj_postcode', prediction.bf_tf_adj_postcode,
                    'bf_premise_address', prediction.bf_premise_address,
                    'bf_tf_adj_premise_address', prediction.bf_tf_adj_premise_address,
                    'bf_premise_number_token', prediction.bf_premise_number_token,
                    'bf_property_class', prediction.bf_property_class
                ) as score_components,
                cast({sql_literal(scored_at)} as timestamptz) as scored_at
            from prediction
            inner join identity.identity_candidate_pair as candidate
                on candidate.identity_run_key = {sql_literal(identity_run_key)}
               and candidate.run_observation_key_l = prediction.canonical_id_l
               and candidate.run_observation_key_r = prediction.canonical_id_r
            inner join identity.identity_scoring_input as left_input
                on candidate.run_observation_key_l = left_input.unique_id
            inner join identity.identity_scoring_input as right_input
                on candidate.run_observation_key_r = right_input.unique_id
        """
        connection.execute("begin transaction")
        try:
            inserted_count = int(connection.execute(insert_sql).fetchone()[0])
            if inserted_count != expected_count:
                raise RuntimeError(
                    "National score publication closure failed: "
                    f"expected {expected_count:,}, inserted {inserted_count:,}"
                )
            completed_at = _now()
            connection.execute(
                """
                update identity.identity_splink_run
                set completed_at = ?, run_status = 'SUCCEEDED',
                    expected_candidate_count = ?, scored_candidate_count = ?
                where splink_run_id = ?
                """,
                [completed_at, expected_count, inserted_count, splink_run_id],
            )
            connection.execute(
                """
                insert into identity.identity_splink_publication
                values (?, ?, ?, ?)
                """,
                [identity_run_key, splink_run_id, model_sha256, completed_at],
            )
            connection.execute(
                """
                insert into identity.identity_splink_publication_event
                values (?, ?, ?, ?, ?)
                """,
                [uuid.uuid4(), identity_run_key, splink_run_id, model_sha256, completed_at],
            )
            connection.execute("commit")
        except Exception:
            connection.execute("rollback")
            raise

        try:
            linker.table_management.delete_tables_created_by_splink_from_db()
        except Exception as cleanup_error:  # pragma: no cover - cleanup is non-authoritative
            LOGGER.warning("Splink scratch cleanup failed after publication: %s", cleanup_error)
        LOGGER.info(
            "National run %s persisted %s scores",
            splink_run_id,
            f"{inserted_count:,}",
        )
        return splink_run_id
    except Exception as error:
        connection.execute(
            """
            update identity.identity_splink_run
            set completed_at = ?, run_status = 'FAILED', failure_message = ?
            where splink_run_id = ?
            """,
            [_now(), str(error)[:4000], splink_run_id],
        )
        raise
    finally:
        connection.close()


def run_benchmark(args: argparse.Namespace) -> uuid.UUID:
    connection = duckdb.connect(str(args.database))
    connection.execute(f"set threads = {args.threads}")
    connection.execute("set memory_limit = ?", [args.memory_limit])
    connection.execute("set preserve_insertion_order = false")
    connection.execute("create schema if not exists identity_work")
    _create_audit_table(connection)

    identity_run_id, identity_run_key, model_version = _current_identity_run(connection)
    splink_run_id = uuid.uuid4()
    linker_uid = f"epcv4_{identity_run_key[:12]}_{model_version}"
    settings = create_settings(
        salting_partitions=args.salting_partitions,
        linker_uid=linker_uid,
    )
    sample_predicate = (
        "substr(sha256(concat_ws(':', 'P01', postcode, premise_address_comparison)), "
        f"1, 2) <= '{args.sample_hex_max}' or "
        "substr(sha256(concat_ws(':', 'P02', postcode_sector, "
        f"premise_address_comparison)), 1, 2) <= '{args.sample_hex_max}' or "
        "substr(sha256(concat_ws(':', 'P04', postcode, unit_identifier_comparison, "
        "building_number_designator)), "
        f"1, 2) <= '{args.sample_hex_max}' or "
        "(source_dataset = 'EPC_CERTIFICATE' and uprn is not null and "
        f"substr(sha256(concat('D01:', uprn)), 1, 2) <= '{args.sample_hex_max}')"
    )
    output_directory = args.output_root / identity_run_key / str(splink_run_id)
    output_directory.mkdir(parents=True, exist_ok=False)
    model_path = output_directory / "splink_model.json"
    settings_json = _settings_json(settings)

    connection.execute(
        """
        insert into identity.identity_splink_run (
            splink_run_id, identity_run_id, identity_run_key, run_mode,
            model_version, model_status, splink_version, duckdb_version,
            settings_json, training_sample_predicate, started_at, run_status
        ) values (?, ?, ?, 'BENCHMARK', ?, 'UNCALIBRATED', ?, ?, ?, ?, ?, 'RUNNING')
        """,
        [
            splink_run_id,
            identity_run_id,
            identity_run_key,
            model_version,
            splink.__version__,
            duckdb.__version__,
            settings_json,
            sample_predicate,
            _now(),
        ],
    )

    try:
        LOGGER.info("Materialising deterministic block-preserving training sample")
        connection.execute(
            f"""
            create or replace table identity_work.splink_training_input as
            select *
            from identity.identity_scoring_input
            where {sample_predicate}
            """
        )
        training_count = connection.execute(
            "select count(*) from identity_work.splink_training_input"
        ).fetchone()[0]

        connection.execute("set schema = 'identity_work'")
        db_api = DuckDBAPI(connection=connection)
        linker = Linker("splink_training_input", settings, db_api=db_api)
        LOGGER.info("Estimating u probabilities from %s random pairs", f"{args.u_pairs:,}")
        linker.training.estimate_u_using_random_sampling(max_pairs=args.u_pairs, seed=42)
        LOGGER.info("Estimating m probabilities on same-UPRN training blocks")
        linker.training.estimate_parameters_using_expectation_maximisation(
            CustomRule(D01_SQL, salting_partitions=args.salting_partitions)
        )
        LOGGER.info("Estimating remaining m probabilities on exact-premise training blocks")
        linker.training.estimate_parameters_using_expectation_maximisation(
            CustomRule(P01_SQL, salting_partitions=args.salting_partitions)
        )
        linker.misc.save_model_to_json(str(model_path), overwrite=True)

        LOGGER.info("Scoring all benchmark candidates without a score threshold")
        predictions = linker.inference.predict(
            threshold_match_probability=None,
            materialise_after_computing_term_frequencies=True,
            materialise_blocked_pairs=True,
        )
        prediction_table = predictions.physical_name
        scored_count = connection.execute(f"select count(*) from {prediction_table}").fetchone()[0]
        expected_count = connection.execute(
            """
            select count(*)
            from identity.identity_candidate_pair as candidate
            inner join identity_work.splink_training_input as left_input
                on candidate.run_observation_key_l = left_input.unique_id
            inner join identity_work.splink_training_input as right_input
                on candidate.run_observation_key_r = right_input.unique_id
            where candidate.identity_run_key = ?
            """,
            [identity_run_key],
        ).fetchone()[0]
        if scored_count != expected_count:
            raise RuntimeError(
                "Splink benchmark candidate closure failed: "
                f"expected {expected_count:,}, scored {scored_count:,}"
            )

        connection.execute(
            f"""
            create table if not exists identity.identity_match_score_benchmark as
            select
                uuid '{splink_run_id}' as splink_run_id,
                varchar '{identity_run_key}' as identity_run_key,
                *
            from {prediction_table}
            where false
            """
        )
        connection.execute(
            f"""
            insert into identity.identity_match_score_benchmark
            select
                uuid '{splink_run_id}' as splink_run_id,
                varchar '{identity_run_key}' as identity_run_key,
                *
            from {prediction_table}
            """
        )
        model_sha256 = _sha256_file(model_path)
        connection.execute(
            """
            update identity.identity_splink_run
            set completed_at = ?, run_status = 'SUCCEEDED',
                training_record_count = ?, expected_candidate_count = ?,
                scored_candidate_count = ?, model_path = ?, model_sha256 = ?
            where splink_run_id = ?
            """,
            [
                _now(),
                training_count,
                expected_count,
                scored_count,
                str(model_path),
                model_sha256,
                splink_run_id,
            ],
        )
        LOGGER.info(
            "Benchmark run %s scored %s candidates",
            splink_run_id,
            f"{scored_count:,}",
        )
        return splink_run_id
    except Exception as error:
        connection.execute(
            """
            update identity.identity_splink_run
            set completed_at = ?, run_status = 'FAILED', failure_message = ?
            where splink_run_id = ?
            """,
            [_now(), str(error)[:4000], splink_run_id],
        )
        raise
    finally:
        connection.close()


def main() -> None:
    args = _parse_args()
    logging.basicConfig(
        level=getattr(logging, args.log_level.upper()),
        format="%(asctime)s %(levelname)s %(message)s",
    )
    if args.mode == "benchmark":
        print(run_benchmark(args))
    else:
        print(run_national(args))


if __name__ == "__main__":
    main()
