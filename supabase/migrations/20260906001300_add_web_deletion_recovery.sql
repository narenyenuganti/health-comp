-- Operator-only recovery helper. Not callable by application API roles.
-- Invoke only on an approved contained restore target, with traffic and workers
-- stopped and transaction/lock timeouts supplied by the recovery operator.
-- This lock serializes database changes; it does not stop a previously admitted
-- external Apple exchange or prove containment of hosted workers.
create function private.invalidate_apple_deletion_web_requests_for_recovery()
returns void language plpgsql security invoker set search_path = ''
set row_security = off as $$
begin
  lock table private.apple_deletion_web_requests in share row exclusive mode;
  -- DELETE fires the existing per-request Vault cleanup trigger. Never TRUNCATE
  -- here, and never touch durable account_deletions or their refresh tokens.
  delete from private.apple_deletion_web_requests;
  -- A restored Vault may also contain codes with no corresponding request.
  -- Literal prefix matching avoids treating underscores as LIKE wildcards.
  delete from vault.secrets
  where pg_catalog.starts_with(name, 'healthcomp_web_deletion_code:');
end;
$$;
revoke all on function private.invalidate_apple_deletion_web_requests_for_recovery()
  from public, anon, authenticated, service_role;
