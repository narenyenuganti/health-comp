# Remote HealthKit Background Durability Design

## Problem

The production multi-user path receives `observerWakeupBackground` through
`HealthKitProvider`, reconciles remote competitions, and then calls HealthKit's
completion handler. Unlike the local Test Lab runtime, it does not first
persist a durable outcome for that observer signal. The physical gate therefore
has no truthful local marker to prove callback ordering, and a storage failure
can still be followed by callback completion.

The August 30 physical retry also ran while the only visible competition was
terminal. Remote competition journals correctly reject local HealthKit refresh
attempts because those journals are restricted to server-accepted rows. A
short genuine Watch workout therefore could not create the marker used by the
old local-runtime receipt, even if HealthKit delivered it successfully.

## Constraints

- Raw HealthKit samples, exact values, goals, workouts, routes, and scores must
  never leave the phone or enter this receipt.
- Remote competition journals remain server-accepted-only.
- The server outbox remains a queue only for server-bound idempotent work.
- Receipt state is profile-scoped, protected after first unlock, removed by the
  existing profile teardown, and bounded on disk.
- HealthKit completion must occur only after the receipt commit succeeds.
- Failed receipt commits remain pending and retry on the next reconciliation or
  profile remount; stopping the runtime must not falsely complete them.
- Foreground, summary, and Realtime behavior must remain unchanged.

## Selected design

Add a `BackgroundDelivery` fixed child to
`AuthenticatedProfileStoragePaths`. A small actor-backed store owns one
versioned, bounded JSON document in that directory. Each receipt contains only
a process-unique signal ID, the closed `ActivityRefreshTrigger`, a local
processed time, a publication revision, and a closed `hadIssues` boolean. It
contains no profile ID, competition ID, HealthKit datum, score, error string,
token, or server payload. Writes use the repository's no-follow, permission,
file-protection, size-limit, and atomic-replacement conventions.

`RemoteCompetitionClientCoordinator` receives a profile-scoped receipt client
when mounting. For a completion-bearing environment signal it performs the
canonical reconciliation, commits the privacy-safe receipt, and only then calls
`completeSignal`. If commit fails, the signal remains pending and is retried
after the next canonical reconciliation. Profile remount also replays the
provider-owned pending signal. Signals without completion requirements keep
their existing path and do not create receipts.

`HealthKitProviderSignalState` makes signal IDs process-unique so retained
receipts cannot conflict across launches. The physical gate can then count the
closed trigger string in the protected receipt document without opening or
retaining any private data.

## Rejected alternatives

1. **Write `ActivityRefreshAttemptRecorded` into remote journals.** Rejected
   because CompetitionCore deliberately forbids local HealthKit evidence in a
   remote journal.
2. **Reuse the server outbox.** Rejected because a local callback receipt is not
   server work and must not affect server idempotency or retry contracts.
3. **Treat a score or file-size change as proof.** Rejected because terminal
   competitions and unchanged quantized scores can legitimately produce no
   score revision, making the physical result ambiguous.

## Verification

Automated tests must prove receipt-before-completion ordering, persistence
failure retry, stop/remount behavior, profile teardown, protected bounded
storage, process-unique signal IDs, and no regression in the existing remote,
HealthKit, storage, and Core suites. A later signed physical retry must observe
the privacy-safe receipt marker after a genuine HealthKit event; it must not
retain the workout, Health values, score, identity, or receipt contents.
