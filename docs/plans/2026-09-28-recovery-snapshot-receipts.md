# Bind recovery receipts to the exported snapshot

## Boundary

Continue the approved local native PostgreSQL export/restore seam from
`2026-09-20-recovery-common-snapshot.md`, on
`test/recovery-snapshot-receipts`, based on merged66cf133. No hosted connection,
credential, phone, private export, paid target or production policy change.

The existing two-table harness already proves `pg_dump --snapshot` against a
concurrent commit. The operational history/state receipt entry points cannot
yet import that snapshot; each begins its own repeatable-read transaction.
First close that missing connection-level behavior, then qualify a complete
real-schema manifest separately. Do not call this a full backup rehearsal.

## Smallest RED/GREEN slice

Reuse the existing held exporter, native clients, isolated empty fixture guard,
literal before/after rows, restore test and owned-resource cleanup. Exercise
byte-identical copies of both actual wrappers, substituting only their relative
query includes with the existing synthetic receipt query. This tests transaction
binding, not the correctness or completeness of either actual receipt query.

1. After the concurrent commit, pass `recovery_snapshot` to each wrapper; demand
   the original literal receipt. Observe actual RED before changing wrappers.
2. Add an optional, SQL-literal-quoted `SET TRANSACTION SNAPSHOT` immediately
   after BEGIN and before any query. Omitting the variable must keep current
   behavior. Preserve READ ONLY, rollback, timeouts and SQLSTATE-only errors.
3. Require both wrappers to see before-state when bound, after-state when
   unbound, and reject malformed/expired snapshots without receipt output.
4. Retain the existing bound-dump restore and unbound-dump negative control.
5. Run existing wrapper/state guard suites and static checks, review independently,
   then integrate after exact-head/resulting-main CI. Do not duplicate live CI.

## Limits

PostgreSQL MVCC snapshot sharing does not freeze sequences, cluster roles or
every external/managed service. The complete application/Auth/Vault/migration
manifest, a genuine deleted participant's history, real TLS and quarantine,
target/cost authority, RPO/RTO and forward repair still require their own proof.
The operational backup runbook remains NOT QUALIFIED FOR EXECUTION.

## Local evidence

The first actual run failed `bound_wrapper_receipt_mismatch` on the unchanged
history wrapper. After adding its snapshot import, that wrapper passed and the
unchanged state wrapper failed `recovery-state-acceptance_bound_receipt_mismatch`.
Adding the same import there produced GREEN for both bound/unbound receipts,
malformed-input rejection, expired-snapshot rejection and the existing native
bound/unbound dump-and-restore controls. Every run removed its owned fixtures.

The new stderr assertions exposed a harness warning: libpq treats `/dev/null`
as a non-regular password file. Reused the existing wrapper suites' checked-
absent password path instead; no credential fallback was enabled. A separate
expected-error correction uses the observed PostgreSQL17 SQLSTATE22023 for
malformed snapshot names and42704 for expired names. An attempted shell trace
itself contaminated captured stderr and is not counted as behavioral evidence.

Local runtime: the previously pinned official PostgreSQL17 image
`postgres@sha256:639ab7ceb90e13123085b741fb31ef493fba25463002f6da665352e7b534b652`,
run only in owned OrbStack container `healthcomp-snapshot-receipts-20260928`:
no network/ports/host mounts, read-only root, bounded tmpfs, one CPU,512MiB memory
and128-process limit. Native tests use a90-second timeout with5-second kill grace.
Existing history wrapper guards passed6/6 and the full state/query/wrapper suite
completed0, including exact cleanup and preservation of pre-existing roles.
Bash syntax, ShellCheck, runbook structure/negative controls, the state static
controls, secret guard and diff check passed. Native runtime was PostgreSQL
17.11. A final independent query found zero fixture schemas, public relations,
restore databases or other active fixture transactions. The exact owned
container was stopped and removed; its label-filtered inventory is empty.
Review follow-up makes every wrapper call start with adverse error settings,
so the wrappers must establish their own error privacy and fail-closed behavior.
It also covers explicitly empty and whitespace-only snapshot variables and
separates exit, stdout and stderr failures by wrapper and expected SQLSTATE.
The empty value initially failed the proposed22023 assertion; a direct native
PostgreSQL17.11 check returnedXX000, while whitespace returned22023. The tests
now require those observed codes, not a guessed common error category.
The focused snapshot, history and state suites passed again. The final empty
fixture/transaction counts were independently queried, not inferred from the
test's narrower built-in guard.

No hosted work ran. Final independent review and exact-head/resulting-main CI
remain pending; this is not full-schema snapshot or recovery qualification.

References: [PostgreSQL 17 snapshot import](https://www.postgresql.org/docs/17/sql-set-transaction.html)
and [native dump snapshot](https://www.postgresql.org/docs/17/app-pgdump.html).
