-- Synthetic, committed fixture setup for separate fresh audit connections.
-- The harness first proves the exact disposable database is empty. It owns and
-- explicitly drops these five tables and two schemas; no CASCADE/role/grant changes.
create schema private;
create schema recovery_fk_reference;

create table public."recovery fk parent" (
  id uuid primary key,
  server_seq bigint unique,
  "first key" bigint,
  "second key" bigint,
  unique ("first key", "second key")
);
insert into public."recovery fk parent" values
  ('00000000-0000-0000-0000-000000000001', 1, 11, 22),
  ('00000000-0000-0000-0000-000000000002', 9223372036854775806, 33, 44);

-- This synthetic third schema represents a reference outside public/private;
-- it is not an Auth fixture and contains no managed or private account data.
create table recovery_fk_reference.recovery_fk_external (
  id uuid primary key,
  text_key text unique
);
insert into recovery_fk_reference.recovery_fk_external values
  ('00000000-0000-0000-0000-000000000001', 'synthetic');

create table public.recovery_fk_single (
  profile_id uuid,
  server_seq bigint,
  external_id uuid,
  text_key text,
  constraint "shared fk" foreign key (profile_id) references public."recovery fk parent" (id),
  constraint recovery_fk_sequence foreign key (server_seq) references public."recovery fk parent" (server_seq),
  constraint recovery_fk_external foreign key (external_id) references recovery_fk_reference.recovery_fk_external (id)
);
insert into public.recovery_fk_single values
  ('00000000-0000-0000-0000-000000000001', 1, '00000000-0000-0000-0000-000000000001', 'synthetic'),
  ('00000000-0000-0000-0000-000000000002', 9223372036854775806, null, null),
  (null, null, null, null);

-- Asymmetric tuples and a reversed physical source-column order make incorrect
-- independent membership checks and conkey/confkey alignment observable.
create table private."recovery fk child" (
  "second key" bigint,
  "first""key" bigint,
  constraint "shared fk" foreign key ("first""key", "second key")
    references public."recovery fk parent" ("first key", "second key") match simple
);
insert into private."recovery fk child" values
  (22, 11), (44, 33), (999, null), (null, 999), (null, null);

create table public.recovery_fk_reverse (
  first_key bigint,
  second_key bigint,
  constraint "shared fk" foreign key (first_key, second_key)
    references public."recovery fk parent" ("second key", "first key") match simple
);
insert into public.recovery_fk_reverse values
  (22, 11), (44, 33), (999, null), (null, 999), (null, null);
