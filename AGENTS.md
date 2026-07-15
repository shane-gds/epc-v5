# EPC v4 implementation guidance

Read `docs/epc-v4-data-model-design.md` before implementing any model.

## Non-negotiable principles

1. Declare and test model grain.
2. Preserve source facts and raw lineage.
3. Use namespaced SHA-256 keys for immutable records/events.
4. Use persistent registry UUIDs for evolving premises/building/dwelling entities.
5. Preserve Splink candidates, decisions, alternatives and singleton outcomes.
6. Keep buildings, dwellings and unresolved premises candidates distinct.
7. Derive current EPC state only for an explicit `as_of_date`.
8. Treat MEES output as cautious policy-versioned screening.
9. Transform distinct coordinate pairs once; retain coordinate method and precision.
10. Build graph exports from contracted dbt marts with endpoint closure.

Do not introduce shortcuts from epc-v3 without documenting and approving the design change.
