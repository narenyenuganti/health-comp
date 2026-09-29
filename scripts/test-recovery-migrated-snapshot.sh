#!/usr/bin/env bash
# Local synthetic component test only. Never point this at hosted or existing data.
set -euo pipefail
umask 077
export LC_ALL=C
script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(CDPATH='' cd -- "$script_dir/.." && pwd)
image='supabase/postgres@sha256:99b1729aeb0bac314445024fc149fbd39306170b61dd50800ccf180327ab3459'
manifest_hash='554117d710521c71eb4a52473a2e2d62d996118814b585aa5b5d7c09222e1b95'
checks=/opt/healthcomp-recovery-checks
fail() { printf 'migrated_snapshot_test: %s\n' "$1" >&2; exit 1; }
[[ $# == 0 ]] || fail unexpected_arguments
for tool in docker supabase jq awk shasum python3 pg_isready; do command -v "$tool" >/dev/null || fail missing_tool; done
[[ $(docker context show) == orbstack ]] || fail orbstack_required
# Pin both Docker and the CLI's client to the same local OrbStack endpoint.
endpoint=$(docker context inspect orbstack --format '{{.Endpoints.docker.Host}}') || fail orbstack_endpoint
[[ $endpoint == unix://*/.orbstack/run/docker.sock ]] || fail local_orbstack_required
export DOCKER_CONTEXT=orbstack DOCKER_HOST="$endpoint"
unset DOCKER_TLS_VERIFY DOCKER_CERT_PATH
daemon_id=$(docker info --format '{{.ID}}') || fail docker_daemon
[[ -n $daemon_id ]] || fail docker_daemon_identity
[[ $(supabase --version) == 2.113.0 ]] || fail supabase_cli_version
engine=$(docker version --format '{{.Server.Version}}') || fail docker_engine
if [[ $engine =~ ^([0-9]+)\. ]] && (( BASH_REMATCH[1] >= 28 )); then :
else fail docker_engine_28_required; fi
pinned_id=$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null) || fail pinned_image_not_local
[[ $pinned_id == sha256:* ]] || fail pinned_image_id
mapfile -t migrations < <(cd "$repo" && printf '%s\n' supabase/migrations/*.sql)
[[ ${#migrations[@]} == 21 ]] || fail migration_count
actual_hash=$(cd "$repo" && shasum -a 256 "${migrations[@]}" | shasum -a 256 | awk '{print $1}')
[[ $actual_hash == "$manifest_hash" ]] || fail migration_manifest
versions=''
for file in "${migrations[@]}"; do
  name=${file##*/}
  version=${name%%_*}
  [[ $version =~ ^[0-9]{14}$ ]] || fail migration_name
  versions+="$version"$'\n'
done
versions=${versions%$'\n'}

scratch=$(mktemp -d /tmp/healthcomp-migrated-local.XXXXXX)
[[ $scratch =~ ^/tmp/healthcomp-migrated-local\.[A-Za-z0-9]{6}$ ]] || fail scratch_path
printf '%s\n' 'synthetic local recovery test' >"$scratch/owner-marker"
suffix=$(printf '%s' "${scratch##*.}" | tr '[:upper:]' '[:lower:]')
project="healthcomp-recovery-$suffix"
source_name="supabase_db_$project"
cache_name="supabase_edge_runtime_$project"
target_name="healthcomp-restore-$suffix"
network_name="healthcomp-recovery-net-$suffix"
source_network=$network_name
owner_label="healthcomp.local-recovery=$project"
source_id='' target_id='' network_id='' source_volume='' exporter_pid=''
source_attempted=0 target_attempted=0
project_resources() {
  docker ps -aq --no-trunc --filter "label=com.supabase.cli.project=$project" &&
    docker volume ls -q --filter "label=com.supabase.cli.project=$project" &&
    docker network ls -q --no-trunc --filter "label=com.supabase.cli.project=$project"
}
stop_exporter() {
  [[ -n $exporter_pid ]] || return 0
  local status=0
  printf 'rollback;\n\\q\n' >&3 || status=1
  exec 3>&-
  wait "$exporter_pid" || status=1
  exporter_pid=''
  exec 4>&-
  return "$status"
}
cleanup() {
  local result=$? status=0 resources expected=''
  trap - EXIT
  stop_exporter || status=1
  # Never use broad CLI stop: a failed bootstrap does not establish ownership.
  [[ $(docker info --format '{{.ID}}') == "$daemon_id" ]] || status=1
  [[ -z $source_id ]] || expected="$source_id"$'\n'"$source_name"
  resources=$(project_resources) || status=1
  [[ $resources == "$expected" ]] || status=1
  docker volume inspect "$cache_name" >/dev/null 2>&1 && status=1
  if (( source_attempted )) && [[ -z $source_id ]]; then status=1; fi
  if (( target_attempted )) && [[ -z $target_id ]]; then status=1; fi
  if [[ -n $source_id ]]; then
    [[ $(docker inspect "$source_id" --format '{{.Id}} {{.Image}} {{index .Config.Labels "com.supabase.cli.project"}} {{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{end}}') == "$source_id $pinned_id $project $source_network" ]] || status=1
    [[ $(docker volume inspect "$source_name") == "$source_volume" ]] || status=1
  fi
  if [[ -n $target_id ]]; then
    [[ $(docker inspect "$target_id" --format '{{.Id}} {{.Image}} {{index .Config.Labels "healthcomp.local-recovery"}} {{.HostConfig.NetworkMode}}') == "$target_id $pinned_id $project none" ]] || status=1
  fi
  if [[ -n $network_id ]]; then
    [[ $(docker network inspect "$network_id" --format '{{.Id}} {{index .Labels "healthcomp.local-recovery"}}') == "$network_id $project" ]] || status=1
  fi
  # Check the whole boundary before the first removal; uncertain state is retained.
  if (( status == 0 )); then
    if [[ -n $target_id ]]; then docker rm -f "$target_id" >/dev/null || status=1; fi
    if [[ -n $source_id ]]; then
      docker rm -f "$source_id" >/dev/null || status=1
      if (( status == 0 )); then docker volume rm "$source_name" >/dev/null || status=1; fi
    fi
    if [[ -n $network_id ]]; then docker network rm "$network_id" >/dev/null || status=1; fi
    resources=$(project_resources) || status=1
    [[ -z $resources ]] || status=1
    docker container inspect "$target_name" >/dev/null 2>&1 && status=1
    docker container inspect "$source_name" >/dev/null 2>&1 && status=1
    docker volume inspect "$source_name" >/dev/null 2>&1 && status=1
    docker volume inspect "$cache_name" >/dev/null 2>&1 && status=1
    docker network inspect "$network_name" >/dev/null 2>&1 && status=1
  fi
  if (( status == 0 )) && [[ -f $scratch/owner-marker && $scratch =~ ^/tmp/healthcomp-migrated-local\.[A-Za-z0-9]{6}$ ]]; then
    if (( result == 0 )); then
      rm -rf -- "$scratch" || status=1
    else
      printf 'migrated_snapshot_test: synthetic_diagnostics_retained (%s)\n' "$scratch" >&2
    fi
  fi
  if (( status != 0 )); then
    printf 'migrated_snapshot_test: owned_cleanup_incomplete (%s)\n' "$scratch" >&2
    result=1
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
existing=$(project_resources) || fail project_inventory
[[ -z $existing ]] || fail preexisting_project_resource
for object in "$source_name" "$target_name"; do
  docker container inspect "$object" >/dev/null 2>&1 && fail preexisting_container
done
docker volume inspect "$source_name" >/dev/null 2>&1 && fail preexisting_volume
docker volume inspect "$cache_name" >/dev/null 2>&1 && fail preexisting_cache
docker network inspect "$network_name" >/dev/null 2>&1 && fail preexisting_network

# CLI bootstrap needs host TCP. Only the empty source is connected; detach before fixtures.
docker network create --driver bridge \
  --opt com.docker.network.bridge.host_binding_ipv4=127.0.0.1 \
  --label "$owner_label" "$network_name" >"$scratch/network-id" || fail network_create
network_id=$(<"$scratch/network-id")
[[ $network_id =~ ^[0-9a-f]{64}$ ]] || fail network_identity
[[ $(docker network inspect "$network_name" --format '{{.Internal}} {{index .Options "com.docker.network.bridge.host_binding_ipv4"}}') == 'false 127.0.0.1' ]] || fail network_boundary
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
mkdir -p "$scratch/project/supabase/migrations"
for file in "${migrations[@]}"; do cp "$repo/$file" "$scratch/project/supabase/migrations/"; done
awk -v project="$project" -v port="$port" '
  /^project_id = / {print "project_id = \"" project "\""; next}
  /^\[db\]$/ {section="db"; print; next}
  /^\[db.seed\]$/ {section="seed"; print; next}
  /^\[experimental.pgdelta\]$/ {section="cache"; print; next}
  /^\[/ {section=""; print; next}
  section=="db" && /^port = / {print "port = " port; next}
  section=="seed" && /^enabled = / {print "enabled = false"; next}
  section=="cache" && /^enabled = / {print "enabled = false"; next}
  {print}
' "$repo/supabase/config.toml" >"$scratch/project/supabase/config.toml"
source_attempted=1
env -i PATH="$PATH" HOME="$HOME" LC_ALL=C DOCKER_HOST="$endpoint" \
  supabase db start --workdir "$scratch/project" --network-id "$network_name" \
  >"$scratch/source-output" 2>"$scratch/source-error" || fail source_start
docker volume inspect "$cache_name" >/dev/null 2>&1 && fail unexpected_cli_cache
[[ $(docker inspect "$source_name" --format '{{index .Config.Labels "com.supabase.cli.project"}} {{.Image}}') == "$project $pinned_id" ]] || fail source_identity_or_image
docker inspect "$source_name" --format '{{json .NetworkSettings.Ports}}' |
  jq -e --arg port "$port" '. == {"5432/tcp":[{"HostIp":"127.0.0.1","HostPort":$port}]}' >/dev/null || fail source_host_binding
host_ready() {
  [[ ! -e $scratch/no-password && ! -L $scratch/no-password ]] || return 3
  env -i PATH="$PATH" LC_ALL=C PGPASSFILE="$scratch/no-password" PGSSLMODE=disable \
    pg_isready -q -h 127.0.0.1 -p "$port" -U postgres -d postgres -t 2
}
host_ready || fail source_host_postgres_not_ready
[[ $(docker inspect "$source_name" --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{end}}') == "$network_name" ]] || fail source_network
docker inspect "$source_name" --format '{{json .Mounts}}' |
  jq -e --arg name "$source_name" 'length == 1 and .[0].Type == "volume" and .[0].Name == $name and .[0].Destination == "/var/lib/postgresql/data"' >/dev/null || fail source_volume_boundary
source_volume=$(docker volume inspect "$source_name") || fail source_volume_identity
jq -e --arg project "$project" 'length == 1 and .[0].Labels["com.supabase.cli.project"] == $project and (.[0].CreatedAt | type == "string")' <<<"$source_volume" >/dev/null || fail source_volume_label
source_id=$(docker inspect "$source_name" --format '{{.Id}}') || fail source_container_id
[[ $source_id =~ ^[0-9a-f]{64}$ ]] || fail source_container_identity

sql_user() {
  local container=$1 username=$2 error_file="$scratch/sql-error.$BASHPID" idle_ms=120000
  shift 2
  if [[ ${1:-} == --held-snapshot ]]; then idle_ms=600000; shift; fi
  : >"$error_file"
  docker exec -i "$container" env PGOPTIONS="-c statement_timeout=30000 -c lock_timeout=3000 -c idle_in_transaction_session_timeout=$idle_ms" \
    psql -XqAt --no-password --host=/var/run/postgresql --username="$username" \
    --dbname=postgres --set=ON_ERROR_STOP=on --set=VERBOSITY=sqlstate \
    --set=SHOW_CONTEXT=never "$@" 2>"$error_file" &&
    [[ ! -s "$error_file" ]]
}
sql() { local container=$1; shift; sql_user "$container" postgres "$@"; }
sql_user "$source_name" supabase_admin -c "alter system set cron.launch_active_jobs = 'off'" >/dev/null || fail source_cron_set
[[ $(sql_user "$source_name" supabase_admin -c 'select pg_reload_conf();') == t ]] || fail source_cron_reload
[[ $(sql "$source_name" -c "select current_setting('cron.launch_active_jobs');") == off ]] || fail source_cron
[[ $(sql "$source_name" -c 'select version from supabase_migrations.schema_migrations order by version;') == "$versions" ]] || fail source_migrations
[[ $(sql "$source_name" -c 'select count(*) from auth.users;') == 0 ]] || fail source_not_empty
[[ $(sql "$source_name" -c 'select count(*) from vault.secrets;') == 0 ]] || fail source_vault_not_empty
docker network disconnect "$network_id" "$source_id" || fail source_disconnect
source_network=''
[[ $(docker inspect "$source_id" --format '{{json .NetworkSettings.Networks}}') == '{}' ]] || fail source_still_connected
docker inspect "$source_id" --format '{{json .NetworkSettings.Ports}}' |
  jq -e '. == null or all(.[]; . == null or . == [])' >/dev/null || fail source_still_published
# OrbStack can still accept proxy TCP after detachment; require no PostgreSQL response.
host_status=0
host_ready || host_status=$?
[[ $host_status == 2 ]] || fail source_host_postgres_still_reachable
[[ $(sql "$source_id" -c 'select 1;') == 1 ]] || fail source_socket_after_disconnect

target_attempted=1
docker run --detach --rm --name "$target_name" --label "$owner_label" \
  --network none --cpus 1 --memory 1g --pids-limit 256 \
  --tmpfs /var/lib/postgresql/data:rw,size=512m --tmpfs /tmp:rw,size=128m \
  --env POSTGRES_HOST_AUTH_METHOD=trust "$image" \
  postgres -D /etc/postgresql -c cron.launch_active_jobs=off >"$scratch/target-id" || fail target_start
target_id=$(<"$scratch/target-id")
[[ $target_id =~ ^[0-9a-f]{64}$ ]] || fail target_container_identity
ready=0
for (( attempt=0; attempt<30; attempt++ )); do
  if docker exec "$target_name" pg_isready --host=/var/run/postgresql --username=postgres >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
(( ready )) || fail target_not_ready
[[ $(docker inspect "$target_name" --format '{{index .Config.Labels "healthcomp.local-recovery"}} {{.Image}} {{.HostConfig.NetworkMode}}') == "$project $pinned_id none" ]] || fail target_identity
docker inspect "$target_name" --format '{{json .NetworkSettings.Ports}}' |
  jq -e 'all(.[]?; . == null or . == [])' >/dev/null || fail target_published_ports
docker inspect "$target_name" --format '{{json .HostConfig.PortBindings}}' |
  jq -e '. == null or . == {}' >/dev/null || fail target_configured_ports
[[ $(sql "$target_name" -c "select current_setting('cron.launch_active_jobs');") == off ]] || fail target_cron
[[ $(sql "$target_name" -c "select current_setting('cron.database_name');") == postgres ]] || fail target_cron_not_loaded
roles_sql="select rolname,rolcanlogin,rolcreaterole,rolinherit,rolsuper,rolcreatedb,rolreplication,rolbypassrls,rolconnlimit from pg_roles where rolname in ('supabase_functions_admin','supabase_realtime_admin') order by rolname;"
expected_roles=$'supabase_functions_admin|t|t|f|f|f|f|f|-1\nsupabase_realtime_admin|f|f|f|f|f|f|f|-1'
[[ $(sql "$source_name" -c "$roles_sql") == "$expected_roles" ]] || fail source_managed_roles
sql_user "$target_name" supabase_admin -c "do \$\$ begin
  if not exists (select 1 from pg_roles where rolname='supabase_functions_admin') then
    create role supabase_functions_admin login createrole noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname='supabase_realtime_admin') then
    create role supabase_realtime_admin nologin noinherit;
  end if;
end \$\$;" >/dev/null || fail target_managed_roles
[[ $(sql "$target_name" -c "$roles_sql") == "$expected_roles" ]] || fail target_managed_role_attributes

for container in "$source_name" "$target_name"; do
  docker exec "$container" mkdir -p "$checks" || fail check_directory
  for file in recovery-history-integrity.sql recovery-history-integrity-query.sql \
    recovery-state-acceptance.sql recovery-state-acceptance-query.sql recovery-foreign-key-integrity.sql; do
    docker cp "$script_dir/$file" "$container:$checks/$file" || fail check_copy
    docker exec "$container" test -s "$checks/$file" || fail check_missing
  done
done
sql_user "$source_name" supabase_admin -c "alter database postgres set healthcomp.recovery_fixture = 'synthetic-20260928'" >/dev/null || fail fixture_marker
state_empty=$(sql "$source_name" -f "$checks/recovery-state-acceptance.sql") || fail empty_state_read
bash "$script_dir/test-recovery-state-acceptance.sh" --check-empty-receipt <<<"$state_empty" || fail empty_state

history_matches() {
  jq -e -s --argjson batch "$1" '
    length==1 and (.[0] |
    type=="object" and
    (keys == ["aggregate_complete_result_fingerprint","aggregate_stored_result_hash",
      "change_rows_orphaned","change_rows_total","competitions_checked",
      "competitions_invalid_sequence","receipt_version","results_format2_checked",
      "results_format2_invalid","results_legacy_unverified","results_total","results_unsupported"]) and
    .receipt_version==1 and .competitions_checked==$batch and
    .change_rows_total==($batch*4) and .results_total==$batch and
    .results_format2_checked==$batch and .competitions_invalid_sequence==0 and
    .change_rows_orphaned==0 and .results_format2_invalid==0 and
    .results_legacy_unverified==0 and .results_unsupported==0 and
    (.aggregate_stored_result_hash | type=="string" and test("^[0-9a-f]{64}$")) and
    (.aggregate_complete_result_fingerprint | type=="string" and test("^[0-9a-f]{64}$")))
  ' >/dev/null
}
state_matches() {
  bash "$script_dir/test-recovery-state-acceptance.sh" --check-migrated-fixture-receipt "$1" >/dev/null
}
sql "$source_name" -v batch=1 <"$script_dir/tests/recovery-migrated-fixture.sql" >/dev/null || fail batch1_fixture
history_before=$(sql "$source_name" -f "$checks/recovery-history-integrity.sql") || fail batch1_history
state_before=$(sql "$source_name" -f "$checks/recovery-state-acceptance.sql") || fail batch1_state
history_matches 1 <<<"$history_before" || fail batch1_history_literal
state_matches 1 <<<"$state_before" || fail batch1_state_literal
[[ $(sql "$source_name" -c 'select count(*) from auth.users;') == 2 ]] || fail batch1_auth

mkfifo "$scratch/input" "$scratch/snapshot"
exec 3<>"$scratch/input"
exec 4<>"$scratch/snapshot"
sql "$source_name" --held-snapshot <"$scratch/input" >"$scratch/snapshot" 2>"$scratch/exporter-error" 3>&- 4>&- &
exporter_pid=$!
printf 'begin isolation level repeatable read read only;\nselect pg_export_snapshot();\n' >&3
IFS= read -r -t 10 snapshot <&4 || fail snapshot_export
[[ $snapshot =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{8}-[0-9]+$ ]] || fail snapshot_shape
sql "$source_name" -v batch=2 <"$script_dir/tests/recovery-migrated-fixture.sql" >/dev/null || fail batch2_fixture
history_after=$(sql "$source_name" -f "$checks/recovery-history-integrity.sql") || fail batch2_history
state_after=$(sql "$source_name" -f "$checks/recovery-state-acceptance.sql") || fail batch2_state
history_matches 2 <<<"$history_after" || fail batch2_history_literal
state_matches 2 <<<"$state_after" || fail batch2_state_literal
[[ $(sql "$source_name" -c 'select count(*) from auth.users;') == 4 ]] || fail batch2_auth
[[ $history_after != "$history_before" && $state_after != "$state_before" ]] || fail control_did_not_change
for key in aggregate_stored_result_hash aggregate_complete_result_fingerprint; do
  [[ $(jq -r --arg key "$key" '.[$key]' <<<"$history_before") != $(jq -r --arg key "$key" '.[$key]' <<<"$history_after") ]] || fail control_hash_unchanged
done
[[ $(sql "$source_name" -v "recovery_snapshot=$snapshot" -f "$checks/recovery-history-integrity.sql") == "$history_before" ]] || fail snapshot_history
[[ $(sql "$source_name" -v "recovery_snapshot=$snapshot" -f "$checks/recovery-state-acceptance.sql") == "$state_before" ]] || fail snapshot_state

for mode in bound unbound; do
  dump_args=()
  if [[ $mode == bound ]]; then
    printf 'select 1;\n' >&3
    IFS= read -r -t 10 alive <&4 && [[ $alive == 1 ]] || fail exporter_not_alive
    dump_args=("--snapshot=$snapshot")
  fi
  docker exec "$source_name" pg_dump --no-password --host=/var/run/postgresql \
    --username=supabase_admin --dbname=postgres --format=custom --lock-wait-timeout=5s \
    "${dump_args[@]}" >"$scratch/archive" 2>"$scratch/dump-error" || fail "${mode}_dump"
  [[ ! -s "$scratch/dump-error" ]] || fail "${mode}_dump_warning"
  if [[ $mode == bound ]]; then
    stop_exporter || fail exporter_termination
    # The archive is complete; no restore needs to hold the source snapshot open.
    rejected_status=0
    docker exec "$source_name" psql -XqAt --no-password --host=/var/run/postgresql \
      --username=postgres --dbname=postgres --set="recovery_snapshot=$snapshot" \
      -f "$checks/recovery-history-integrity.sql" \
      >"$scratch/rejected-output" 2>"$scratch/rejected-error" || rejected_status=$?
    [[ $rejected_status == 3 && ! -s "$scratch/rejected-output" ]] || fail expired_snapshot_not_rejected
    awk '$0 !~ /^psql:.*:[0-9]+: ERROR:[[:space:]]+42704$/ {bad=1}
      END {if (bad || NR != 1) exit 1}' "$scratch/rejected-error" || fail expired_snapshot_error
  fi
  [[ $(docker inspect "$target_name" --format '{{index .Config.Labels "healthcomp.local-recovery"}} {{.HostConfig.NetworkMode}}') == "$project none" ]] || fail target_recheck
  docker exec "$target_name" psql -XqAt --no-password --host=/var/run/postgresql \
    --username=supabase_admin --dbname=template1 --set=ON_ERROR_STOP=on \
    -c 'drop database postgres with (force)' -c 'create database postgres template template0' \
    >"$scratch/restore-output" 2>"$scratch/restore-error" || fail "${mode}_empty_target"
  docker exec -i "$target_name" pg_restore --no-password --host=/var/run/postgresql \
    --username=supabase_admin --dbname=postgres --exit-on-error --single-transaction \
    --clean --if-exists <"$scratch/archive" >"$scratch/restore-output" 2>"$scratch/restore-error" || fail "${mode}_restore"
  [[ ! -s "$scratch/restore-error" ]] || fail "${mode}_restore_warning"
  [[ $(sql "$target_name" -c 'select version from supabase_migrations.schema_migrations order by version;') == "$versions" ]] || fail "${mode}_migrations"
  history_restored=$(sql "$target_name" -f "$checks/recovery-history-integrity.sql") || fail "${mode}_history"
  state_restored=$(sql "$target_name" -f "$checks/recovery-state-acceptance.sql") || fail "${mode}_state"
  if [[ $mode == bound ]]; then
    expected_history=$history_before expected_state=$state_before expected_batch=1 expected_auth=2
  else
    expected_history=$history_after expected_state=$state_after expected_batch=2 expected_auth=4
    [[ $history_restored != "$history_before" && $state_restored != "$state_before" ]] || fail unbound_not_detected
  fi
  history_matches "$expected_batch" <<<"$history_restored" || fail "${mode}_history_literal"
  state_matches "$expected_batch" <<<"$state_restored" || fail "${mode}_state_literal"
  [[ $history_restored == "$expected_history" && $state_restored == "$expected_state" ]] || fail "${mode}_receipt_mismatch"
  [[ $(sql "$target_name" -c 'select count(*) from auth.users;') == "$expected_auth" ]] || fail "${mode}_auth"
  foreign_keys=$(sql "$target_name" -f "$checks/recovery-foreign-key-integrity.sql") || fail "${mode}_foreign_keys"
  [[ -z $foreign_keys ]] || fail "${mode}_foreign_key_output"
  [[ $(sql "$target_name" -c "select current_setting('cron.launch_active_jobs');") == off ]] || fail "${mode}_cron"
  printf 'migrated_%s_restore_and_actual_receipts_passed\n' "$mode"
done
printf '%s\n' 'full_migrated_database_dump_restore_component_passed_not_hosted_qualification'
