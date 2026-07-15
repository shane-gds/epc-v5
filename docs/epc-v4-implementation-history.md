# EPC v4 implementation and decision history

**Status:** Active running record
**Started:** 15 July 2026
**Authoritative design:** `docs/epc-v4-data-model-design.md`

## 1. Purpose

This document records implementation steps, material choices, validation evidence,
operational constraints and unresolved decisions as EPC v4 is built. It is intended to
preserve the reasoning needed for later formal documentation and architecture decision
records.

This is not a replacement for the authoritative data-model design or future ADRs. When
an implementation choice changes a documented contract, the change must be called out
here and promoted to `docs/decisions/` before it is treated as approved architecture.

## 2. Recording convention

Each material decision has a stable identifier of the form `IMP-###`. Work-log entries
are timestamped in UTC. Validation entries record the actual command or gate and the
observed result. Counts refer to the currently registered local releases unless an entry
states otherwise.

Statuses used below:

- `Accepted`: implemented and supported by passing gates.
- `Provisional`: suitable for the current phase but requires calibration or governance.
- `Open`: not yet decided.
- `Superseded`: retained for history but no longer active.

## 3. Current implementation position

| Area | Current state | Evidence |
|---|---|---|
| Source control | Private GitHub repository on `main` | Commits `cdf89cd`, `bdb8389` |
| Audit and Bronze | Complete for current PPD, domestic EPC and ONSUD inputs | 42 leaf files reconciled |
| Silver | Four canonical observation/allocation models complete | 183,755,287 accepted rows |
| Quarantine | Append-only fatal-rule evidence | 11 EPC source rows |
| Identity input | Run-versioned PP/EPC observation population | 54,920,040 observations |
| Location input | Explicit ONSUD `DEC_2025` required-UPRN outcomes | 17,929,367 UPRNs |
| Identity candidates | Complete for current benchmark policy | 26,301,482 pairs |
| Identity scoring | Complete, explicitly uncalibrated | 26,301,482 Splink scores |
| Identity outcomes | Review decisions and singleton/unresolved closure complete | 54,869,297 hypotheses |
| Core registries and facts | Not started | Planned after Phase 2 gates |
| Current-state and MEES marts | Not started | Planned Phase 5 |
| Graph export | Not started | Planned Phase 6 |

## 4. Chronological implementation history

### 4.1 Greenfield design and scaffold

- EPC v4 was established as a greenfield project. EPC v3 is historical reference only
  and is not an implementation contract.
- DuckDB and dbt were selected as the analytical system of record. Neo4j remains a
  bounded projection target rather than the primary store.
- The authoritative design was consolidated in
  `docs/epc-v4-data-model-design.md` with explicit grains, lineage, key strategies,
  tests and non-goals.
- The initial project scaffold established Python 3.12, dbt-duckdb, Splink, spatial
  support, Ruff, SQLFluff and pytest.

### 4.2 Source-data transfer and preservation

- The source-import directory was copied from EPC v3 to
  `data/raw/epc project data files/`.
- All five copied files were verified against their source copies with SHA-256 before
  the EPC v3 source directory was emptied.
- The retained source set contains:
  - HM Land Registry Price Paid Data complete CSV.
  - Domestic EPC annual certificate and recommendation CSV members for 2012-2026.
  - ONSUD December 2025 regional CSV members and publisher documentation.
  - 2025 LAD and LPA reference CSVs retained for later reference modelling.
- Raw data, DuckDB databases, local environments and generated artifacts are excluded
  from Git.

### 4.3 Audited Bronze ingestion

- A bounded source importer was implemented in `src/epc_v4/import_sources.py`.
- ZIP archives are hashed and registered, then processed one member at a time.
- Each member is extracted, hashed, parsed serially for deterministic source row
  numbering, loaded transactionally, reconciled, checkpointed and deleted before the
  next member.
- Empty strings are preserved in source-shaped `VARCHAR` columns.
- Immutable source-row keys use namespaced SHA-256 over file/member content identity
  and parser row position. These are evidence keys, not business-entity keys.
- National Bronze counts:

| Bronze relation | Rows |
|---|---:|
| `bronze.raw_pp_transaction` | 31,346,259 |
| `bronze.raw_epc_certificate` | 23,573,792 |
| `bronze.raw_epc_recommendation` | 87,448,794 |
| `bronze.raw_onsud_uprn` | 41,386,453 |
| **Total** | **183,755,298** |

### 4.4 Silver observations and quarantine

- Shared postcode, address, EPC-band, GBP-cost and strict-integer parsing macros were
  introduced.
- The four canonical Silver models were materialised:
  - `silver.stg_pp_transaction_observation`
  - `silver.stg_epc_certificate_observation`
  - `silver.stg_epc_recommendation_observation`
  - `silver.stg_onsud_uprn_allocation`
- Fatal validation is represented by append-only
  `audit.quarantine_source_record` events. Unsupported or ambiguous non-fatal values
  remain in Silver with explicit statuses rather than being invented or dropped.
- DuckDB integer casts were not used directly for identifiers because they round decimal
  strings. Strict lexical integer validation now precedes UPRN, coordinate and item
  conversion.
- Recommendation cost parsing accepts explicit GBP ranges/single values only. Bare
  numbers, non-GBP currencies, mojibake, invalid bounds and unsupported text retain
  null numeric values plus a status.
- Current Silver reconciliation:

| Source family | Bronze | Accepted | Quarantined |
|---|---:|---:|---:|
| PPD | 31,346,259 | 31,346,259 | 0 |
| EPC certificate | 23,573,792 | 23,573,781 | 11 |
| EPC recommendation | 87,448,794 | 87,448,794 | 0 |
| ONSUD | 41,386,453 | 41,386,453 | 0 |
| **Total** | **183,755,298** | **183,755,287** | **11** |

- The 11 quarantined rows are EPC certificates missing inspection dates.
- Seven recommendation observations are retained as explicit orphans because their four
  parent certificates are among those quarantined observations.
- No natural-key conflict is present in the current EPC/ONSUD release, but adversarial
  exact-duplicate and conflict fixtures are implemented so these paths do not pass
  vacuously.

### 4.5 Initial identity and location intermediates

- Identity populations are deterministic and run-versioned from the registered PP/EPC
  release and top-level source-file checksums.
- `identity.identity_run_manifest` is append-only. Re-running unchanged inputs does not
  add a run or duplicate observations.
- `identity.int_identity_observation` has one PP/EPC source observation per immutable
  identity run. PPD duration and EPC tenure remain separate semantic fields.
- Current identity eligibility outcomes:

| Outcome | Observations |
|---|---:|
| `ELIGIBLE` | 54,869,297 |
| `INELIGIBLE_INVALID_POSTCODE` | 380 |
| `INELIGIBLE_MISSING_ADDRESS` | 8 |
| `INELIGIBLE_MISSING_POSTCODE` | 50,355 |
| **Total** | **54,920,040** |

- Location requirements explicitly select ONSUD release `DEC_2025`.
- Current location outcomes:

| Outcome | UPRNs |
|---|---:|
| `RESOLVED_UNIQUE` | 17,921,199 |
| `MISSING_IN_RELEASE` | 8,168 |
| **Total required UPRNs** | **17,929,367** |

- Missing and conflicting outcomes do not expose arbitrary location or coordinate facts.

## 5. Decision register

### IMP-001: Preserve source facts before interpretation

**Status:** Accepted

Bronze retains publisher representations as strings with source release, file, archive
member, parser row and pipeline-run lineage. Parsing and policy interpretation occur in
later layers.

### IMP-002: Use bounded archive extraction

**Status:** Accepted

Only one archive member is expanded at a time. Successful row reconciliation is required
before temporary data is deleted. This keeps disk demand bounded and supports restartable
member-level ingestion.

### IMP-003: Separate evidence keys from entity identifiers

**Status:** Accepted

Immutable rows/events use namespaced SHA-256 contracts. Evolving registry entities will
receive persistent UUIDs only after an explicit promotion decision.

### IMP-004: Record unknown legacy release metadata honestly

**Status:** Accepted, governance follow-up open

The copied PPD and EPC files do not include complete retrieval/license metadata. Their
local release labels explicitly state that they are legacy control labels. Missing
publisher dates and licensing decisions are not inferred.

### IMP-005: Treat parsing ambiguity as status, not repair

**Status:** Accepted

Unsupported postcode/cost/coordinate/tenure representations remain null in typed fields
with explicit statuses. Mojibake and non-GBP currencies are not silently repaired.

### IMP-006: Quarantine only fatal source-row failures

**Status:** Accepted

Quarantine events are append-only and one row is emitted per failed fatal rule. Replay
status and original quarantine time survive subsequent dbt runs.

### IMP-007: Reconcile every loaded leaf file through Silver

**Status:** Accepted

The file manifest, rather than observed raw rows, drives Silver reconciliation. This
includes loaded zero-row files and detects orphan raw file identifiers. Publication to
`audit_source_file` is blocked on complete, fresh, distinct and passing file coverage.

### IMP-008: Select geography releases explicitly

**Status:** Accepted

Location intermediates use the configured ONSUD label `DEC_2025`; there is no implicit
"latest" release behavior.

### IMP-009: Transform coordinates only after distinct-pair contraction

**Status:** Accepted design; implementation pending

BNG coordinate pairs will be deduplicated and transformed once. Coordinate method, CRS,
precision and status will be retained.

### IMP-010: Version identity input populations

**Status:** Accepted

Identity runs are derived from release keys, source checksums and algorithm/normalizer
contracts. Run manifests and observation membership are append-only, enabling candidate,
score and decision evidence to reference an immutable population.

### IMP-011: Preserve singletons, alternatives and unresolved outcomes

**Status:** Accepted design; implementation pending

Every eligible observation must receive an explicit cluster, singleton or unresolved
outcome. Accepted links must not erase rejected or lower-scoring alternatives.

### IMP-012: Keep PPD duration and EPC tenure semantically separate

**Status:** Accepted

Freehold/leasehold duration and assessment-time occupancy tenure are not treated as a
shared identity comparison field.

### IMP-013: Candidate generation must be bounded and attributable

**Status:** Provisional pending benchmark

Every candidate pair must record the blocking rule(s) that produced it. All-to-all joins
are prohibited. Per-block fan-out, candidate counts, peak memory and spill volume must be
measured before national scoring.

### IMP-014: Splink thresholds require calibration evidence

**Status:** Open

No acceptance/rejection threshold will be represented as production policy until it is
versioned and tested against collision, flat/sub-building, postcode-history, UPRN-conflict
and singleton fixtures. Initial thresholds may be labelled benchmark-only.

### IMP-015: Registry promotion is distinct from match scoring

**Status:** Accepted design; implementation pending

Candidate scoring does not itself create a premises/building/dwelling registry entity.
Promotion requires an explicit decision policy and persistent UUID allocation.

### IMP-016: Use a source-neutral premise comparator for identity

**Status:** Accepted

The original Silver address fields are intentionally source-shaped and are not directly
comparable: PPD included town/district/county while EPC omitted posttown. Identity input
version `identity_address_v2` now derives premise-only text from PPD
PAON/SAON/street/locality and EPC address lines 1-3. The original source-normalized value
is retained separately.

### IMP-017: Prohibit postcode-only national blocking

**Status:** Accepted

Exact postcode alone produces 2,031,286,542 candidate pairs, including 869,994,429
cross-source pairs. It is recorded as a prohibited rule in the versioned blocking policy
and must fail configuration validation if enabled.

### IMP-018: Treat same supplied UPRN as identifier evidence, not dwelling identity

**Status:** Accepted

The current EPC population contains 523,547 UPRNs with multiple premise descriptions and
2,531,968 same-UPRN pairs with discordant premise text. The largest supplied UPRN group
has 502 observations and 502 distinct premise descriptions. Same-UPRN candidates are
retained as direct-identifier evidence but cannot alone promote a dwelling or premises
registry component.

### IMP-019: Keep postcode-plus-number fallback disabled pending calibration

**Status:** Provisional

Postcode plus first numeric token produces 29,708,048 cross-source pairs. A provisional
cap of 250 records per source side and 10,000 cross-products suppresses 362,718 pairs,
but the first number can represent a flat, building number or numbered name. Rule
`P03_POSTCODE_NUMBER` remains benchmark-only and disabled until structured unit/street
parsing and recall evidence are available.

### IMP-020: Make enabled candidate rules mutually exclusive

**Status:** Accepted for benchmark policy v1

`P02_SECTOR_PREMISE_EXACT` is defined as same sector and premise with a differing full
postcode. It therefore contributes only the 19,973 recovery pairs not admitted by P01.
This preserves one rule-hit row per current candidate and avoids a memory-heavy national
pair aggregation while retaining rule provenance. Future overlapping policies require a
review of the pair-summary implementation before enablement.

### IMP-021: Persist uncalibrated scores but prohibit acceptance and promotion

**Status:** Accepted

Splink model `splink_benchmark_v1` is trained without labelled calibration evidence. All
national scores are retained, but every decision is `REVIEW`, every accepted-edge flag is
false and persistent registry tables remain empty. Match probabilities must not be
treated as production-calibrated probabilities.

### IMP-022: Rank observation alternatives without using them for promotion

**Status:** Provisional

All pair scores are retained. A view exposes observation-endpoint ranking and margins,
but repeated observations can represent corroboration rather than mutually exclusive
premises targets. These ranks cannot drive acceptance until target-group semantics are
defined.

### IMP-023: Use single-thread execution for high-cardinality endpoint aggregation

**Status:** Accepted operational profile

Both combined and left-only endpoint aggregation exceeded the 12 GB DuckDB memory limit
with four execution threads. Running the same left aggregation with one DuckDB thread
succeeded in 69 seconds without increasing memory. High-cardinality identity aggregation
commands therefore use `EPC_V4_DUCKDB_THREADS=1`; profile memory and thread limits are
environment-overridable and recorded with execution evidence.

## 6. Validation evidence

The latest completed pre-Phase-2 validation on 15 July 2026 produced:

- 134 of 134 dbt data tests passing.
- 7 of 7 Python tests passing.
- Ruff and SQLFluff passing.
- 42 of 42 loaded leaf source files with `PASSED` Silver reconciliation.
- 183,755,298 Bronze rows equal to 183,755,287 accepted plus 11 quarantined rows.
- Identity incremental idempotency confirmed for unchanged inputs.
- Quarantine incremental idempotency confirmed with original timestamps unchanged.
- Explicit adversarial fixtures passing for strict integer parsing, EPC conflict
  classification, ONSUD conflict classification and recommendation-parent outcomes.

The completed Phase 2 identity checkpoint later on 15 July 2026 produced:

- 96 of 96 identity and singular acceptance tests passing.
- 110 of 110 complementary non-identity/source tests passing.
- 206 of 206 dbt tests passing in two bounded processes.
- 8 of 8 Python tests passing.
- dbt parsing, Ruff and SQLFluff model lint passing.
- Candidate, score and decision counts reconciled at 26,301,482.
- Eligible identity observations and hypotheses reconciled by count and an
  order-independent endpoint checksum at 54,869,297.
- Zero accepted edges and zero promoted registry records under the uncalibrated policy.

## 7. Active Phase 2 plan

The following sequence is active. This section will be updated as work progresses.

1. Profile the eligible identity population and benchmark bounded blocking rules.
2. Version candidate-generation and comparison policies in the identity-run contract.
3. Materialise deterministic direct-identifier and address/postcode candidate evidence.
4. Integrate Splink scoring while retaining component features and total weights.
5. Persist candidate alternatives and explicit decision outcomes.
6. Build run-versioned cluster membership with singleton and unresolved closure.
7. Introduce persistent registry UUID allocation only after promotion gates pass.
8. Benchmark national candidate volume, memory, spill and runtime.
9. Run repeatability, collision, transitive-chain and no-silent-drop acceptance tests.

## 8. Active work log

### 2026-07-15 10:13 UTC: Phase 2 initiated

- User requested continuation into identity resolution and a running implementation
  history for later documentation.
- Available filesystem capacity was verified at approximately 222 GB before Phase 2.
- The Git working tree was clean on `main` at commit `bdb8389`.
- Immediate next action: profile eligible observations and candidate-block cardinalities
  without materialising national candidate pairs.

### 2026-07-15 10:20 UTC: Initial blocking benchmark

- Added reproducible read-only profiler `scripts/profile_identity_blocks.py`.
- The first inline profiling command failed with a Python quoting error before executing
  SQL; no database state changed.
- The source-shaped address comparator produced zero exact cross-source address matches,
  exposing a comparability defect rather than a genuine absence of matches.
- Initial benchmark results:

| Rule | Total pairs | Cross-source pairs | Maximum block |
|---|---:|---:|---:|
| Exact supplied UPRN | 8,429,004 | 0 | 502 |
| Exact postcode plus old source-shaped address | 21,777,405 | 0 | 49 |
| Exact postcode plus first number | 100,008,877 | 29,708,048 | 722 |
| Exact postcode only | 2,031,286,542 | 869,994,429 | 1,268 |

### 2026-07-15 10:35 UTC: Identity input v2 and policy versioning

- Added seed `identity_blocking_policy.csv` with deterministic, probabilistic,
  benchmark-only and prohibited rule classes.
- Identity run keys now include the blocking-policy fingerprint, input algorithm,
  address normalizer, eligibility contract, comparison model and decision policy.
- Corrected `identity_observation_key` to be run-independent and added a separate
  run-observation key.
- Introduced source-neutral `premise_address_comparison` and retained the original
  source address comparison.
- The pre-Phase-2 input-only run was superseded during this schema migration because it
  had no candidate, score, decision or registry evidence.

### 2026-07-15 10:38 UTC: Identity input v2 blocking benchmark

| Rule | Total pairs | Cross-source pairs | Maximum block | Cross pairs suppressed by provisional cap |
|---|---:|---:|---:|---:|
| `D01_EXACT_UPRN` | 8,429,004 | 0 | 502 | 0 |
| `P01_POSTCODE_PREMISE_EXACT` | 40,554,881 | 17,852,505 | 49 | 0 |
| `P02_SECTOR_PREMISE_EXACT` | 40,610,603 | 17,872,478 | 55 | 0 |
| `P03_POSTCODE_NUMBER` | 100,008,877 | 29,708,048 | 722 | 362,718 |
| Exact premise address | 137,947,390 | 65,905,696 | 340 | 4,016,672 |
| Exact postcode | 2,031,286,542 | 869,994,429 | 1,268 | 75,136,775 |

- `P01` is accepted for benchmark scoring.
- `P02` is accepted as a narrow postcode-change recovery rule; incremental unique-pair
  contribution must still be measured.
- `P03` remains disabled.
- Exact postcode and unrestricted exact premise address are not admitted.

### 2026-07-15 10:40 UTC: Supplied UPRN heterogeneity profile

- Added reproducible profiler `scripts/profile_identity_uprn_groups.py`.
- Profiled 17,929,367 UPRN groups covering 23,268,650 EPC observations.
- 523,547 groups contain multiple premise descriptions.
- 5,962 groups contain multiple postcodes.
- 211,535 groups contain multiple property-type values.
- 8,429,008 same-UPRN pairs comprise 5,897,040 exact-premise pairs and 2,531,968
  discordant-premise pairs.
- Decision: preserve same-UPRN evidence, but do not treat it as automatic dwelling or
  premises identity.

### 2026-07-15 10:45 UTC: First national candidate materialisation attempt

- Materialised 44,153,987 immutable rule-hit rows for the initial overlapping policy.
- The rule-hit build completed in 8 minutes 18 seconds.
- Pair aggregation was killed by the VM memory limit before commit because P01 and P02
  produced a duplicated 17.85 million-pair rule-hit set.
- The database remained consistent: rule hits committed, candidate pairs did not.

### 2026-07-15 10:59 UTC: Mutually exclusive policy revision

- Added `rule_logic_version` to policy and rule-hit evidence.
- Changed P02 to same sector/premise with a different full postcode (`p02_v2`).
- Created a new policy-fingerprinted identity run rather than mutating the aborted run.
- Preserved the aborted run's 44,153,987 rule hits and backfilled their explicit logic
  versions (`p02_v1` for the former overlapping rule).
- Current run rule hits and candidate pairs:

| Rule | Current rule hits |
|---|---:|
| `D01_EXACT_UPRN` | 8,429,004 |
| `P01_POSTCODE_PREMISE_EXACT` | 17,852,505 |
| `P02_SECTOR_PREMISE_EXACT` | 19,973 |
| **Candidate pairs** | **26,301,482** |

- Candidate pair materialisation completed in 29 seconds after rule-hit generation.
- Candidate endpoint/rule/pair closure gates passed. A historical null-version test
  initially failed, then passed after the explicit backfill migration.

### 2026-07-15 11:30 UTC: First Splink benchmark

- Installed versions recorded: Splink 4.0.16 and DuckDB 1.5.4.
- The first deterministic sample selected 1,208,171 records and scored exactly 559,419
  expected candidates.
- It preserved D01/P01 blocks but selected only six P02 pairs because sampling was keyed
  by endpoint postcode rather than the complete P02 block.
- Model artifact and SHA-256 were persisted; this run was retained as benchmark evidence
  but not selected for national scoring.

### 2026-07-15 11:35 UTC: Block-preserving Splink benchmark

- Sampling was changed to hash complete D01, P01 and P02 block keys.
- Training population: 2,054,108 records.
- Expected/scored benchmark candidates: 850,102, including 273 P02 pairs.
- Selected model SHA-256:
  `3a05774267aac360300059017f4d80263aaf58bbda43c2157c8fd2746b4ab711`.
- The model remains `UNCALIBRATED`; fixed UPRN comparison assumptions and unsupervised
  m/u estimates are retained in the model JSON and run manifest.

### 2026-07-15 11:40 UTC: National Splink scoring

- National Splink run ID: `ac7ebcbd-ad83-4edc-91b1-8dcb1bc96961`.
- Expected candidates: 26,301,482.
- Persisted component-level scores: 26,301,482.
- Runtime: 9 minutes 44 seconds.
- Candidate closure was enforced before transactional score publication.
- Score evidence retains match weight/probability, component Bayes factors, derived
  comparison levels, model version/hash, run lineage and blocking rule.
- No score threshold was applied and no candidate was dropped.

### 2026-07-15 11:55 UTC: Decisions and hypothesis closure

- Materialised 26,301,482 decisions in 14 seconds.
- Every decision is `REVIEW`; no accepted edge exists.
- Persistent registry foundation tables were created and remain empty.
- Observation-endpoint alternatives are exposed by a view over all score evidence.
- The initial combined endpoint-summary aggregation exceeded the 12 GB DuckDB memory
  limit and did not commit.
- The summary was split into canonical left/right stages. The right stage committed; the
  left stage still exceeded 12 GB and did not commit.
- Consequently `identity_observation_candidate_summary`, `identity_hypothesis` and
  `identity_cluster_membership` are not yet materialised for the current run.
- Current database size is approximately 89 GB with approximately 197 GB free.
- Next action: rerun only the failed left endpoint stage with reduced DuckDB execution
  threads or a higher tested memory limit, then build hypothesis/singleton closure.

### 2026-07-15 12:34 UTC: Memory-bounded hypothesis closure completed

- Made dbt concurrency, DuckDB execution threads, memory and maximum spill size explicit
  environment-controlled profile settings.
- Rebuilt only `identity_observation_candidate_summary_l` with
  `EPC_V4_DUCKDB_THREADS=1`; it completed in 69 seconds at the existing 12 GB limit.
- Combined endpoint summary completed in 41 seconds.
- National hypothesis materialisation completed in 6 minutes 3 seconds.
- Current outcomes:

| Outcome | Observations | Candidate endpoints |
|---|---:|---:|
| `SINGLETON_NO_CANDIDATE` | 24,945,047 | 0 |
| `UNRESOLVED_REVIEW` | 29,924,250 | 52,602,964 |
| **Total hypotheses** | **54,869,297** | **52,602,964** |

- Maximum candidate fan-out for one endpoint is 501.
- `identity_cluster_membership` exposes one singleton or unresolved-review membership per
  eligible observation. No review-only edge creates a multi-observation component.
- Replaced the memory-heavy population anti-join gate with count plus order-independent
  endpoint checksum reconciliation; runtime reduced from an OOM after 68 seconds to a
  pass in 9 seconds.
- The full 206 dbt tests passed in bounded identity (96) and complementary (110) suites.
- Database size is approximately 94 GB with approximately 192 GB free.

## 9. Open decisions and governance dependencies

- Official retrieval dates and licensing terms for copied legacy PPD/EPC files.
- Production Splink comparison settings, m/u estimates and threshold bands.
- Whether and how transitive links may promote a multi-observation cluster.
- Manual-review workflow and persistence contract.
- Registry continuity rules when later identity runs split or merge prior clusters.
- Premises-candidate to building/dwelling promotion criteria.
- Publication/disclosure policy for precise coordinates and graph exports.
