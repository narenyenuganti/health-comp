# Recipient-bound invitation recovery regression

## Boundary

Requalify the existing native local export/restore harness against PR #148's
23-migration schema, based on `d69b423`, on `test/recipient-invitation-recovery`.
Reuse the approved synthetic-only common-snapshot and forward-repair interfaces.
No hosted service, credentials, phone, live invitation, paid setup, application
migration or production change is in scope. Keep PR #148's head unchanged.

## Smallest complete change

- Resolve the already-cached PostgreSQL image by its exact ECR repository/digest;
  do not change its digest or relax source/target image-identity checks.
- Feed aggregate state receipts through ordinary pipes: the installed macOS
  Bash 5.3.15 stalls on a 2,000-byte here-string, while the same pipe completes.
  Preserve pipefail and the unchanged strict receipt parser. Run that parser's
  standalone static controls with macOS's system Bash.
- Reproduce the stale migration-manifest rejection before updating its exact pin.
- Populate the new immutable recipient column in the current-schema synthetic
  completed-history fixture, and check its exact relationship after both restores.
- Preserve the old-schema forward-repair fixture. Its protected-row comparison
  must expect only the new nullable column on old completed rows, not ignore the
  column or loosen any existing data/security comparison.
- Run both existing native modes serially, each timeout-bounded to 600 seconds,
  retaining TLS, unbound-snapshot, expired-snapshot, omitted/duplicate-repair,
  actual history/state/FK and ownership-scoped cleanup controls.
- Run syntax, ShellCheck, existing static runbook/state tests, and independent
  Standards/Spec review before a separate exact-head CI integration.

## Limits

This updates local synthetic component evidence only. Hosted recovery, genuine
anonymized history, deletion reconciliation, operational RPO/RTO and production
readiness remain unqualified. Do not alter those runbook holds.

## Local evidence

October 19: the old 22-migration pin rejected the current schema with
`migration_count`, after resolving the same cached image digest. The first
native attempt stalled at a large here-string on local Bash 5.3.15 and was
stopped; its owned resources were removed and it is not a qualification pass.
A bounded 2,000-byte synthetic reproduction timed out with a here-string and
completed with an ordinary pipe. The strict parser's static controls passed
under system Bash; its parser and acceptance criteria are unchanged.

After changing only state-receipt transport, both native modes exited zero.
The snapshot case restored both bound and unbound archives and checked non-null
recipient identity against the corresponding invitee in each restored batch.
Both cases retained TLS hostname/trust rejection, actual history/state/FK
checks and their existing snapshot/repair negative controls. Forward repair
preserved old completed rows, including the newly added null recipient field.
Independent readback found no owned test containers, volumes or networks; the
four unrelated `hde-test-db` containers remained running.

Bash syntax, ShellCheck, runbook checks and four documentation mutations, strict
state static controls, eleven FK parser controls and diff check passed. No
application source or migration changed. Independent Standards and Spec reviews
of `d69b423...d339558` each returned zero findings. PR #149 subsequently passed
exact-head CI at `c7f6070fdd8c2fd774bd42937aa8984b73cc6da0` and merged as
`9f9fb5e6be8637c8e0e64928cbdf034d6efc2e05` on October 19.

The later 018 trigger-order correction in PR #151 changed the exact migration
manifest again. Both native synthetic modes passed with the updated pin before
its passing exact-head CI and integration as `6635c22`. These remain synthetic
component results, not hosted recovery or production-readiness evidence.
