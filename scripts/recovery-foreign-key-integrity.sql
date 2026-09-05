\set ON_ERROR_STOP on
\set ON_ERROR_ROLLBACK off
\set VERBOSITY sqlstate
\set SHOW_CONTEXT never
begin transaction isolation level repeatable read read only;
set local statement_timeout = '30s';
set local row_security = off;

do $healthcomp_fk_mode_guard$
begin
  if (current_setting('transaction_isolation') = 'repeatable read'
    and current_setting('transaction_read_only') = 'on'
    and current_setting('session_replication_role') = 'origin') is not true
  then raise exception using errcode = 'P0001', message = 'foreign_key_audit_mode'; end if;
end
$healthcomp_fk_mode_guard$;

-- Current HealthComp FK types only, not a generic PostgreSQL verifier.
-- Schema presence/grants and connection freshness are separate prerequisites.
do $healthcomp_fk_audit$
declare
  foreign_key record;
  key_count bigint;
  supported_pairs boolean;
  join_predicate text;
  non_null_predicate text;
  orphan_count bigint;
begin
  for foreign_key in
    select constraint_record.conrelid, constraint_record.confrelid,
      constraint_record.conkey, constraint_record.confkey,
      constraint_record.conpfeqop, constraint_record.confmatchtype,
      constraint_record.conparentid,
      source_namespace.nspname as source_schema,
      source_relation.relname as source_table,
      source_relation.relkind as source_kind,
      source_relation.relispartition as source_partition,
      target_namespace.nspname as target_schema,
      target_relation.relname as target_table,
      target_relation.relkind as target_kind,
      target_relation.relispartition as target_partition
    from pg_catalog.pg_constraint constraint_record
    join pg_catalog.pg_class source_relation
      on source_relation.oid = constraint_record.conrelid
    join pg_catalog.pg_namespace source_namespace
      on source_namespace.oid = source_relation.relnamespace
    join pg_catalog.pg_class target_relation
      on target_relation.oid = constraint_record.confrelid
    join pg_catalog.pg_namespace target_namespace
      on target_namespace.oid = target_relation.relnamespace
    where constraint_record.contype = 'f'
      and source_namespace.nspname in ('public', 'private')
    order by constraint_record.oid
  loop
    -- Partition parents/leaves and FK action clones need different semantics.
    -- A missing/unsupported shape is a stop, never silently skipped.
    if (foreign_key.confmatchtype = 's'
      and foreign_key.conparentid = 0
      and foreign_key.source_kind = 'r' and not foreign_key.source_partition
      and foreign_key.target_kind = 'r' and not foreign_key.target_partition
      and pg_catalog.array_ndims(foreign_key.conkey) = 1
      and pg_catalog.array_ndims(foreign_key.confkey) = 1
      and pg_catalog.array_ndims(foreign_key.conpfeqop) = 1
      and pg_catalog.cardinality(foreign_key.conkey) > 0
      and pg_catalog.cardinality(foreign_key.conkey) = pg_catalog.cardinality(foreign_key.confkey)
      and pg_catalog.cardinality(foreign_key.conkey) = pg_catalog.cardinality(foreign_key.conpfeqop)
    ) is not true then
      raise exception using errcode = '0A000', message = 'foreign_key_unsupported_shape';
    end if;

    select pg_catalog.count(*),
      pg_catalog.bool_and((
        source_attribute.attnum > 0 and not source_attribute.attisdropped
        and target_attribute.attnum > 0 and not target_attribute.attisdropped
        and source_attribute.atttypid in ('pg_catalog.uuid'::pg_catalog.regtype,
          'pg_catalog.int8'::pg_catalog.regtype)
        and target_attribute.atttypid = source_attribute.atttypid
        and source_attribute.attcollation = 0 and target_attribute.attcollation = 0
        and equality_key.operator_oid = case source_attribute.atttypid
          when 'pg_catalog.uuid'::pg_catalog.regtype
            then 'pg_catalog.=(pg_catalog.uuid,pg_catalog.uuid)'::pg_catalog.regoperator
          when 'pg_catalog.int8'::pg_catalog.regtype
            then 'pg_catalog.=(pg_catalog.int8,pg_catalog.int8)'::pg_catalog.regoperator
        end
      ) is true),
      pg_catalog.string_agg(pg_catalog.format(
        'target.%I OPERATOR(pg_catalog.=) source.%I',
        target_attribute.attname, source_attribute.attname
      ), ' and ' order by source_key.ordinal_position),
      pg_catalog.string_agg(pg_catalog.format(
        'source.%I is not null', source_attribute.attname
      ), ' and ' order by source_key.ordinal_position)
    into key_count, supported_pairs, join_predicate, non_null_predicate
    from pg_catalog.unnest(foreign_key.conkey)
      with ordinality as source_key(source_attnum, ordinal_position)
    left join pg_catalog.unnest(foreign_key.confkey)
      with ordinality as target_key(target_attnum, ordinal_position)
      using (ordinal_position)
    left join pg_catalog.unnest(foreign_key.conpfeqop)
      with ordinality as equality_key(operator_oid, ordinal_position)
      using (ordinal_position)
    left join pg_catalog.pg_attribute source_attribute
      on source_attribute.attrelid = foreign_key.conrelid
      and source_attribute.attnum = source_key.source_attnum
    left join pg_catalog.pg_attribute target_attribute
      on target_attribute.attrelid = foreign_key.confrelid
      and target_attribute.attnum = target_key.target_attnum;

    if (key_count = pg_catalog.cardinality(foreign_key.conkey)
      and supported_pairs and join_predicate is not null
      and non_null_predicate is not null) is not true then
      raise exception using errcode = '0A000', message = 'foreign_key_unsupported_comparison';
    end if;

    -- MATCH SIMPLE exempts a tuple if ANY FK component is null. Ordinary
    -- inheritance does not inherit FKs or let a child satisfy its parent's key.
    execute pg_catalog.format(
      'select count(*) from ONLY %I.%I source '
      || 'where (%s) and not exists ('
      || 'select 1 from ONLY %I.%I target where %s)',
      foreign_key.source_schema, foreign_key.source_table, non_null_predicate,
      foreign_key.target_schema, foreign_key.target_table, join_predicate
    ) into orphan_count;
    if orphan_count <> 0 then
      raise exception using errcode = '23503', message = 'foreign_key_orphan';
    end if;
  end loop;
end
$healthcomp_fk_audit$;

rollback;
