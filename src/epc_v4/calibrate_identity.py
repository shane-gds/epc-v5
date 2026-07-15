"""Create, adjudicate and evaluate deterministic identity calibration samples."""

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

from epc_v4.stable_keys import sql_literal, stable_sha256, stable_sha256_sql

LOGGER = logging.getLogger(__name__)
SAMPLE_CONTRACT_VERSION = "identity_calibration_sample_v1"
ALLOWED_LABELS = ("MATCH", "NO_MATCH", "UNSURE")
ALLOWED_TARGET_SCOPES = (
    "SAME_DWELLING",
    "SAME_PREMISES",
    "SAME_BUILDING",
    "DIFFERENT",
    "UNSURE",
)


def _now() -> datetime:
    return datetime.now(UTC)


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def initialize_calibration_tables(connection: duckdb.DuckDBPyConnection) -> None:
    """Create persistent calibration evidence tables without adding labels."""
    connection.execute("create schema if not exists identity")
    connection.execute("create schema if not exists identity_work")
    connection.execute(
        """
        create table if not exists identity.identity_calibration_sample_manifest (
            calibration_sample_id uuid primary key,
            calibration_sample_key varchar not null,
            identity_run_id uuid not null,
            identity_run_key varchar not null,
            splink_run_id uuid not null,
            model_sha256 varchar not null,
            sample_contract_version varchar not null,
            quota_per_stratum integer not null,
            hash_prefix_max varchar not null,
            sampling_parameters json not null,
            created_at timestamptz not null,
            completed_at timestamptz,
            sample_status varchar not null,
            sample_row_count ubigint,
            export_path varchar,
            export_sha256 varchar,
            failure_message varchar
        )
        """
    )
    connection.execute(
        """
        create table if not exists identity.identity_calibration_sample (
            calibration_sample_row_key varchar primary key,
            calibration_sample_id uuid not null,
            calibration_sample_key varchar not null,
            identity_run_id uuid not null,
            identity_run_key varchar not null,
            splink_run_id uuid not null,
            candidate_pair_key varchar not null,
            sample_stratum varchar not null,
            deterministic_stratum_rank integer not null,
            primary_blocking_rule_code varchar not null,
            review_priority varchar not null,
            decision_reason varchar not null,
            match_weight double not null,
            match_probability double not null,
            postcode_comparison_level varchar not null,
            premise_address_comparison_level varchar not null,
            property_class_comparison_level varchar not null,
            endpoint_candidate_count_l ubigint not null,
            endpoint_candidate_count_r ubigint not null,
            target_alternative_count_l ubigint not null,
            target_alternative_count_r ubigint not null,
            target_alternative_rank_l ubigint not null,
            target_alternative_rank_r ubigint not null,
            target_margin_l double,
            target_margin_r double,
            run_observation_key_l varchar not null,
            source_dataset_l varchar not null,
            source_natural_key_l varchar not null,
            premise_address_l varchar not null,
            postcode_l varchar not null,
            uprn_l varchar,
            property_class_l varchar not null,
            event_date_l date not null,
            run_observation_key_r varchar not null,
            source_dataset_r varchar not null,
            source_natural_key_r varchar not null,
            premise_address_r varchar not null,
            postcode_r varchar not null,
            uprn_r varchar,
            property_class_r varchar not null,
            event_date_r date not null,
            sampled_at timestamptz not null
        )
        """
    )
    connection.execute(
        """
        create table if not exists identity.identity_adjudication_label (
            adjudication_label_id uuid primary key,
            calibration_sample_row_key varchar not null,
            calibration_sample_id uuid not null,
            candidate_pair_key varchar not null,
            identity_run_key varchar not null,
            adjudication_label varchar not null,
            target_scope varchar not null,
            adjudicator varchar not null,
            rationale varchar not null,
            label_source varchar not null,
            label_status varchar not null,
            adjudicated_at timestamptz not null,
            supersedes_adjudication_label_id uuid,
            source_file_sha256 varchar not null
        )
        """
    )
    connection.execute(
        """
        create table if not exists identity.identity_calibration_evaluation (
            calibration_evaluation_id uuid not null,
            calibration_sample_id uuid not null,
            identity_run_key varchar not null,
            model_sha256 varchar not null,
            label_snapshot_sha256 varchar not null,
            threshold_match_weight double not null,
            true_positive ubigint not null,
            false_positive ubigint not null,
            false_negative ubigint not null,
            true_negative ubigint not null,
            precision double,
            recall double,
            specificity double,
            f1_score double,
            labelled_pair_count ubigint not null,
            evaluation_status varchar not null,
            evaluated_at timestamptz not null
        )
        """
    )


def _current_scoring_run(connection: duckdb.DuckDBPyConnection) -> tuple[Any, ...]:
    row = connection.execute(
        """
        select
            current_run.identity_run_id,
            current_run.identity_run_key,
            splink_run.splink_run_id,
            splink_run.model_sha256
        from identity.int_identity_current_run as current_run
        inner join identity.identity_splink_run as splink_run
            on current_run.identity_run_key = splink_run.identity_run_key
        where splink_run.run_mode = 'NATIONAL'
          and splink_run.run_status = 'SUCCEEDED'
        qualify row_number() over (order by splink_run.completed_at desc) = 1
        """
    ).fetchone()
    if row is None:
        raise RuntimeError("No successful current national Splink run is available")
    return row


def _sample_key(
    identity_run_key: str,
    model_sha256: str,
    quota_per_stratum: int,
    hash_prefix_max: str,
) -> str:
    return stable_sha256(
        "epc-v4.identity.calibration-sample",
        "v1",
        [
            identity_run_key,
            model_sha256,
            SAMPLE_CONTRACT_VERSION,
            quota_per_stratum,
            hash_prefix_max,
        ],
    )


def create_sample(
    connection: duckdb.DuckDBPyConnection,
    *,
    output_root: Path,
    quota_per_stratum: int,
    hash_prefix_max: str,
) -> tuple[uuid.UUID, Path, int]:
    initialize_calibration_tables(connection)
    identity_run_id, identity_run_key, splink_run_id, model_sha256 = _current_scoring_run(
        connection
    )
    sample_key = _sample_key(
        identity_run_key,
        model_sha256,
        quota_per_stratum,
        hash_prefix_max,
    )
    sample_id = uuid.UUID(hex=sample_key[:32])
    existing = connection.execute(
        """
        select sample_status, export_path, sample_row_count
        from identity.identity_calibration_sample_manifest
        where calibration_sample_key = ?
        """,
        [sample_key],
    ).fetchone()
    if existing and existing[0] == "SUCCEEDED":
        return sample_id, Path(existing[1]), int(existing[2])

    sampling_parameters = json.dumps(
        {
            "contract_version": SAMPLE_CONTRACT_VERSION,
            "quota_per_stratum": quota_per_stratum,
            "hash_prefix_max": hash_prefix_max,
            "hash_function": "sha256",
            "labels_inferred": False,
        },
        sort_keys=True,
    )
    if existing:
        connection.execute(
            "delete from identity.identity_calibration_sample where calibration_sample_id = ?",
            [sample_id],
        )
        connection.execute(
            """
            update identity.identity_calibration_sample_manifest
            set splink_run_id = ?, sampling_parameters = ?, created_at = ?,
                completed_at = null, sample_status = 'RUNNING', sample_row_count = null,
                export_path = null, export_sha256 = null, failure_message = null
            where calibration_sample_id = ?
            """,
            [splink_run_id, sampling_parameters, _now(), sample_id],
        )
    else:
        connection.execute(
            """
            insert into identity.identity_calibration_sample_manifest values (
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, null, 'RUNNING', null, null, null, null
            )
            """,
            [
                sample_id,
                sample_key,
                identity_run_id,
                identity_run_key,
                splink_run_id,
                model_sha256,
                SAMPLE_CONTRACT_VERSION,
                quota_per_stratum,
                hash_prefix_max,
                sampling_parameters,
                _now(),
            ],
        )

    try:
        LOGGER.info("Materialising deterministic calibration pre-sample")
        connection.execute(
            f"""
            create or replace table identity_work.identity_calibration_frame as
            select
                candidate.candidate_pair_key,
                candidate.run_observation_key_l,
                candidate.run_observation_key_r,
                score.primary_blocking_rule_code,
                decision.review_priority,
                decision.decision_reason,
                score.match_weight,
                score.match_probability,
                score.postcode_comparison_level,
                score.premise_address_comparison_level,
                score.property_class_comparison_level,
                left_summary.candidate_count as endpoint_candidate_count_l,
                right_summary.candidate_count as endpoint_candidate_count_r,
                left_target.target_alternative_count as target_alternative_count_l,
                right_target.target_alternative_count as target_alternative_count_r,
                left_target.target_alternative_rank as target_alternative_rank_l,
                right_target.target_alternative_rank as target_alternative_rank_r,
                left_target.margin_to_next_target as target_margin_l,
                right_target.margin_to_next_target as target_margin_r
            from identity.identity_candidate_pair as candidate
            inner join identity.identity_match_decision as decision
                on candidate.candidate_pair_key = decision.candidate_pair_key
            inner join identity.identity_match_score as score
                on candidate.candidate_pair_key = score.candidate_pair_key
               and score.splink_run_id = uuid {sql_literal(str(splink_run_id))}
            inner join identity.identity_observation_candidate_summary as left_summary
                on candidate.run_observation_key_l = left_summary.identity_run_observation_key
            inner join identity.identity_observation_candidate_summary as right_summary
                on candidate.run_observation_key_r = right_summary.identity_run_observation_key
            inner join identity.identity_target_hypothesis as left_hypothesis
                on candidate.run_observation_key_l
                 = left_hypothesis.identity_run_observation_key
            inner join identity.identity_target_hypothesis as right_hypothesis
                on candidate.run_observation_key_r
                 = right_hypothesis.identity_run_observation_key
            inner join identity.identity_target_alternative_ranked as left_target
                on candidate.run_observation_key_l = left_target.identity_run_observation_key
               and right_hypothesis.target_hypothesis_key
                 = left_target.target_hypothesis_key
            inner join identity.identity_target_alternative_ranked as right_target
                on candidate.run_observation_key_r = right_target.identity_run_observation_key
               and left_hypothesis.target_hypothesis_key
                 = right_target.target_hypothesis_key
            where candidate.identity_run_key = {sql_literal(identity_run_key)}
              and substr(
                    sha256(concat({sql_literal(sample_key)}, candidate.candidate_pair_key)),
                    1,
                    2
                  ) <= {sql_literal(hash_prefix_max)}
            """
        )

        score_band = """
            case
                when match_weight < 0 then 'LT_0'
                when match_weight < 10 then '0_TO_10'
                when match_weight < 20 then '10_TO_20'
                when match_weight < 30 then '20_TO_30'
                else 'GE_30'
            end
        """
        fanout_band = """
            case
                when greatest(endpoint_candidate_count_l, endpoint_candidate_count_r) = 1
                    then '1'
                when greatest(endpoint_candidate_count_l, endpoint_candidate_count_r) <= 5
                    then '2_TO_5'
                when greatest(endpoint_candidate_count_l, endpoint_candidate_count_r) <= 20
                    then '6_TO_20'
                else 'GT_20'
            end
        """
        ambiguity_band = """
            case
                when greatest(target_alternative_count_l, target_alternative_count_r) = 1
                    then '1'
                when greatest(target_alternative_count_l, target_alternative_count_r) <= 3
                    then '2_TO_3'
                else 'GT_3'
            end
        """
        agreement_pattern = """
            case
                when primary_blocking_rule_code = 'D01_EXACT_UPRN'
                 and premise_address_comparison_level = 'EXACT'
                 and postcode_comparison_level = 'EXACT' then 'D01_CONSISTENT'
                when primary_blocking_rule_code = 'D01_EXACT_UPRN'
                    then 'D01_HETEROGENEOUS'
                when primary_blocking_rule_code = 'P02_SECTOR_PREMISE_EXACT'
                    then 'P02_POSTCODE_CHANGE'
                else 'P01_EXACT_PREMISE'
            end
        """
        sample_row_key_sql = stable_sha256_sql(
            "epc-v4.identity.calibration-sample-row",
            "v1",
            [sql_literal(sample_key), "candidate_pair_key"],
        )
        sampled_at = _now().isoformat()
        inserted_count = int(
            connection.execute(
                f"""
                insert into identity.identity_calibration_sample
                with stratified as (
                    select
                        *,
                        concat_ws(
                            '|',
                            primary_blocking_rule_code,
                            {score_band},
                            {agreement_pattern},
                            {fanout_band},
                            {ambiguity_band},
                            review_priority
                        ) as sample_stratum
                    from identity_work.identity_calibration_frame
                ),
                ranked as (
                    select
                        *,
                        row_number() over (
                            partition by sample_stratum
                            order by sha256(concat({sql_literal(sample_key)}, candidate_pair_key))
                        ) as deterministic_stratum_rank
                    from stratified
                )
                select
                    {sample_row_key_sql} as calibration_sample_row_key,
                    uuid {sql_literal(str(sample_id))} as calibration_sample_id,
                    {sql_literal(sample_key)} as calibration_sample_key,
                    uuid {sql_literal(str(identity_run_id))} as identity_run_id,
                    {sql_literal(identity_run_key)} as identity_run_key,
                    uuid {sql_literal(str(splink_run_id))} as splink_run_id,
                    ranked.candidate_pair_key,
                    ranked.sample_stratum,
                    ranked.deterministic_stratum_rank,
                    ranked.primary_blocking_rule_code,
                    ranked.review_priority,
                    ranked.decision_reason,
                    ranked.match_weight,
                    ranked.match_probability,
                    ranked.postcode_comparison_level,
                    ranked.premise_address_comparison_level,
                    ranked.property_class_comparison_level,
                    ranked.endpoint_candidate_count_l,
                    ranked.endpoint_candidate_count_r,
                    ranked.target_alternative_count_l,
                    ranked.target_alternative_count_r,
                    ranked.target_alternative_rank_l,
                    ranked.target_alternative_rank_r,
                    ranked.target_margin_l,
                    ranked.target_margin_r,
                    left_input.unique_id,
                    left_input.source_dataset,
                    left_input.source_natural_key,
                    left_input.premise_address_comparison,
                    left_input.postcode,
                    left_input.uprn,
                    left_input.property_class,
                    left_input.event_date,
                    right_input.unique_id,
                    right_input.source_dataset,
                    right_input.source_natural_key,
                    right_input.premise_address_comparison,
                    right_input.postcode,
                    right_input.uprn,
                    right_input.property_class,
                    right_input.event_date,
                    cast({sql_literal(sampled_at)} as timestamptz)
                from ranked
                inner join identity.identity_scoring_input as left_input
                    on ranked.run_observation_key_l = left_input.unique_id
                inner join identity.identity_scoring_input as right_input
                    on ranked.run_observation_key_r = right_input.unique_id
                where ranked.deterministic_stratum_rank <= {quota_per_stratum}
                """
            ).fetchone()[0]
        )

        output_directory = output_root / identity_run_key / "calibration"
        output_directory.mkdir(parents=True, exist_ok=True)
        export_path = output_directory / f"{sample_key}.csv"
        connection.execute(
            f"""
            copy (
                select
                    *,
                    cast(null as varchar) as adjudication_label,
                    cast(null as varchar) as target_scope,
                    cast(null as varchar) as adjudicator,
                    cast(null as varchar) as rationale
                from identity.identity_calibration_sample
                where calibration_sample_id = uuid {sql_literal(str(sample_id))}
                order by sample_stratum, deterministic_stratum_rank
            ) to {sql_literal(str(export_path))} (header, delimiter ',')
            """
        )
        export_sha256 = _sha256_file(export_path)
        connection.execute(
            """
            update identity.identity_calibration_sample_manifest
            set completed_at = ?, sample_status = 'SUCCEEDED', sample_row_count = ?,
                export_path = ?, export_sha256 = ?
            where calibration_sample_id = ?
            """,
            [_now(), inserted_count, str(export_path), export_sha256, sample_id],
        )
        LOGGER.info("Created calibration sample with %s rows", f"{inserted_count:,}")
        return sample_id, export_path, inserted_count
    except Exception as error:
        connection.execute(
            """
            update identity.identity_calibration_sample_manifest
            set completed_at = ?, sample_status = 'FAILED', failure_message = ?
            where calibration_sample_id = ?
            """,
            [_now(), str(error)[:4000], sample_id],
        )
        raise


def import_labels(connection: duckdb.DuckDBPyConnection, labels_path: Path) -> int:
    initialize_calibration_tables(connection)
    source_sha256 = _sha256_file(labels_path)
    connection.execute(
        """
        create or replace table identity_work.identity_label_import as
        select * from read_csv(?, header = true, all_varchar = true)
        """,
        [str(labels_path)],
    )
    invalid = connection.execute(
        f"""
        select count(*)
        from identity_work.identity_label_import
        where nullif(trim(adjudication_label), '') is not null
          and (
            upper(trim(adjudication_label)) not in {ALLOWED_LABELS}
            or upper(trim(target_scope)) not in {ALLOWED_TARGET_SCOPES}
            or nullif(trim(adjudicator), '') is null
            or nullif(trim(rationale), '') is null
          )
        """
    ).fetchone()[0]
    if invalid:
        raise ValueError(f"Label file contains {invalid} invalid completed row(s)")
    unknown = connection.execute(
        """
        select count(*)
        from identity_work.identity_label_import as imported
        left join identity.identity_calibration_sample as sample
            on imported.calibration_sample_row_key = sample.calibration_sample_row_key
        where nullif(trim(imported.adjudication_label), '') is not null
          and sample.calibration_sample_row_key is null
        """
    ).fetchone()[0]
    if unknown:
        raise ValueError(f"Label file references {unknown} unknown sample row(s)")

    connection.execute("begin transaction")
    try:
        connection.execute(
            """
            update identity.identity_adjudication_label as existing
            set label_status = 'SUPERSEDED'
            from identity_work.identity_label_import as imported
            where existing.calibration_sample_row_key = imported.calibration_sample_row_key
              and existing.label_status = 'ACTIVE'
              and nullif(trim(imported.adjudication_label), '') is not null
            """
        )
        inserted = int(
            connection.execute(
                f"""
                insert into identity.identity_adjudication_label
                select
                    uuid() as adjudication_label_id,
                    sample.calibration_sample_row_key,
                    sample.calibration_sample_id,
                    sample.candidate_pair_key,
                    sample.identity_run_key,
                    upper(trim(imported.adjudication_label)),
                    upper(trim(imported.target_scope)),
                    trim(imported.adjudicator),
                    trim(imported.rationale),
                    'MANUAL' as label_source,
                    'ACTIVE' as label_status,
                    current_timestamp as adjudicated_at,
                    previous.adjudication_label_id,
                    {sql_literal(source_sha256)} as source_file_sha256
                from identity_work.identity_label_import as imported
                inner join identity.identity_calibration_sample as sample
                    on imported.calibration_sample_row_key = sample.calibration_sample_row_key
                left join identity.identity_adjudication_label as previous
                    on sample.calibration_sample_row_key = previous.calibration_sample_row_key
                   and previous.label_status = 'SUPERSEDED'
                where nullif(trim(imported.adjudication_label), '') is not null
                qualify row_number() over (
                    partition by sample.calibration_sample_row_key
                    order by previous.adjudicated_at desc nulls last
                ) = 1
                """
            ).fetchone()[0]
        )
        connection.execute("commit")
        return inserted
    except Exception:
        connection.execute("rollback")
        raise


def evaluate_labels(connection: duckdb.DuckDBPyConnection, minimum_labels: int) -> uuid.UUID:
    initialize_calibration_tables(connection)
    label_rows = connection.execute(
        """
        select
            label.calibration_sample_id,
            sample.identity_run_key,
            sample.splink_run_id,
            sample.candidate_pair_key,
            sample.match_weight,
            label.adjudication_label,
            label.target_scope,
            label.adjudication_label_id
        from identity.identity_adjudication_label as label
        inner join identity.identity_calibration_sample as sample
            on label.calibration_sample_row_key = sample.calibration_sample_row_key
        where label.label_status = 'ACTIVE'
          and label.adjudication_label in ('MATCH', 'NO_MATCH')
        order by label.adjudication_label_id
        """
    ).fetchall()
    if len(label_rows) < minimum_labels:
        raise RuntimeError(
            f"Calibration requires at least {minimum_labels} MATCH/NO_MATCH labels; "
            f"found {len(label_rows)}"
        )
    labels = {row[5] for row in label_rows}
    if labels != {"MATCH", "NO_MATCH"}:
        raise RuntimeError("Calibration requires both MATCH and NO_MATCH labels")

    sample_id = label_rows[0][0]
    identity_run_key = label_rows[0][1]
    model_sha256 = connection.execute(
        """
        select model_sha256 from identity.identity_splink_run where splink_run_id = ?
        """,
        [label_rows[0][2]],
    ).fetchone()[0]
    label_snapshot = stable_sha256(
        "epc-v4.identity.label-snapshot",
        "v1",
        [str(row[7]) for row in label_rows],
    )
    evaluation_id = uuid.uuid4()
    connection.execute(
        """
        insert into identity.identity_calibration_evaluation
        with labelled as (
            select
                sample.match_weight,
                label.adjudication_label = 'MATCH' as actual_match
            from identity.identity_adjudication_label as label
            inner join identity.identity_calibration_sample as sample
                on label.calibration_sample_row_key = sample.calibration_sample_row_key
            where label.label_status = 'ACTIVE'
              and label.adjudication_label in ('MATCH', 'NO_MATCH')
        ),
        thresholds as (
            select cast(value as double) as threshold
            from range(-20, 41, 1) as values(value)
        ),
        metrics as (
            select
                threshold,
                count(*) filter (where match_weight >= threshold and actual_match) as tp,
                count(*) filter (where match_weight >= threshold and not actual_match) as fp,
                count(*) filter (where match_weight < threshold and actual_match) as fn,
                count(*) filter (where match_weight < threshold and not actual_match) as tn,
                count(*) as labelled_count
            from labelled
            cross join thresholds
            group by threshold
        )
        select
            ?, ?, ?, ?, ?, threshold, tp, fp, fn, tn,
            tp::double / nullif(tp + fp, 0) as precision,
            tp::double / nullif(tp + fn, 0) as recall,
            tn::double / nullif(tn + fp, 0) as specificity,
            2.0 * precision * recall / nullif(precision + recall, 0) as f1_score,
            labelled_count,
            'EVALUATION_ONLY' as evaluation_status,
            current_timestamp
        from metrics
        """,
        [evaluation_id, sample_id, identity_run_key, model_sha256, label_snapshot],
    )
    return evaluation_id


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("create-sample", "import-labels", "evaluate"))
    parser.add_argument(
        "--database",
        type=Path,
        default=Path("output/duckdb/epc_v4.duckdb"),
    )
    parser.add_argument("--output-root", type=Path, default=Path("output/identity"))
    parser.add_argument("--quota-per-stratum", type=int, default=20)
    parser.add_argument("--hash-prefix-max", default="03")
    parser.add_argument("--labels-path", type=Path)
    parser.add_argument("--minimum-labels", type=int, default=100)
    parser.add_argument("--threads", type=int, default=1)
    parser.add_argument("--memory-limit", default="12GB")
    parser.add_argument("--log-level", default="INFO")
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    logging.basicConfig(
        level=getattr(logging, args.log_level.upper()),
        format="%(asctime)s %(levelname)s %(message)s",
    )
    connection = duckdb.connect(str(args.database))
    connection.execute(f"set threads = {args.threads}")
    connection.execute("set memory_limit = ?", [args.memory_limit])
    connection.execute("set preserve_insertion_order = false")
    try:
        if args.action == "create-sample":
            sample_id, path, count = create_sample(
                connection,
                output_root=args.output_root,
                quota_per_stratum=args.quota_per_stratum,
                hash_prefix_max=args.hash_prefix_max,
            )
            print(f"{sample_id} | {count} rows | {path}")
        elif args.action == "import-labels":
            if args.labels_path is None or not args.labels_path.is_file():
                raise ValueError("--labels-path must identify an adjudicated sample CSV")
            print(f"Imported {import_labels(connection, args.labels_path)} labels")
        else:
            print(evaluate_labels(connection, args.minimum_labels))
    finally:
        connection.close()


if __name__ == "__main__":
    main()
