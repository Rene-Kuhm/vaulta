#!/usr/bin/env bash
#
# Applies every migration in `supabase/migrations/` to a clean PostgreSQL,
# in lexicographic order, the way a deployment would.
#
# Used by `.github/workflows/supabase-migrations-ci.yml`, and usable by hand
# against any PostgreSQL 15+ server:
#
#   PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=postgres \
#     bash supabase/ci/apply_migrations.sh
#
# What it does, in order:
#   1. waits for the server to accept connections;
#   2. applies `supabase/ci/shim_supabase_objects.sql`, the stand-in for the
#      objects Supabase provides (see the comments in that file);
#   3. applies `supabase/migrations/*.sql` sorted by file name, each one with
#      `psql -v ON_ERROR_STOP=1`, so the first failing statement aborts the
#      whole run and this script exits non-zero;
#   4. skips a migration only if `supabase/ci/excluded_migrations.txt` names
#      it explicitly, with a reason. A migration that is neither applied nor
#      listed is an error, and so is a listed file that no longer exists.
#
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"

migrations_dir="${SUPABASE_MIGRATIONS_DIR:-${repo_root}/supabase/migrations}"
shim_file="${script_dir}/shim_supabase_objects.sql"
exclusions_file="${script_dir}/excluded_migrations.txt"

log() { printf '[migrations-ci] %s\n' "$*"; }
fail() { printf '[migrations-ci] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- connection

command -v psql >/dev/null 2>&1 || fail "psql is not installed"

if [ -z "${DATABASE_URL:-}" ] && [ -z "${PGHOST:-}" ]; then
  fail "no database to connect to: set PGHOST/PGPORT/PGUSER/PGDATABASE or DATABASE_URL"
fi

db_args=(--no-psqlrc --quiet)
if [ -n "${DATABASE_URL:-}" ]; then
  db_args+=(--dbname "${DATABASE_URL}")
fi

# ON_ERROR_STOP=1 is what makes a failed statement fail the whole run: psql
# exits non-zero on the first error instead of carrying on with the rest of
# the file.
psql_run() {
  psql -v ON_ERROR_STOP=1 "${db_args[@]}" "$@"
}

# The CI service container is healthy before the first step runs, but a
# developer pointing this at a server that is still booting should not have
# to guess how long to wait.
if [ -z "${DATABASE_URL:-}" ]; then
  for _ in $(seq 1 30); do
    if pg_isready --quiet; then
      break
    fi
    sleep 1
  done
  pg_isready --quiet || fail "the database at ${PGHOST:-?}:${PGPORT:-5432} never became ready"
fi

# --------------------------------------------------------------------- shim

[ -f "${shim_file}" ] || fail "missing shim: ${shim_file}"
log "applying the Supabase stand-in: ${shim_file#"${repo_root}/"}"
psql_run --file "${shim_file}" >/dev/null

# --------------------------------------------------------------- exclusions

# Format: one migration file name per line, then a `|`, then the reason it
# cannot run outside a real Supabase project. Comments and blank lines are
# ignored.
excluded_files=()
excluded_reasons=()

if [ -f "${exclusions_file}" ]; then
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%$'\r'}"
    case "${line}" in
      ''|'#'*) continue ;;
    esac
    file="${line%%|*}"
    reason="${line#*|}"
    file="$(printf '%s' "${file}" | tr -d '[:space:]')"
    reason="$(printf '%s' "${reason}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "${file}" ] || fail "${exclusions_file##*/} has a line without a file name: ${line}"
    [ "${reason}" != "${line}" ] && [ -n "${reason}" ] \
      || fail "${exclusions_file##*/} lists ${file} without a reason: a migration is never skipped silently"
    excluded_files+=("${file}")
    excluded_reasons+=("${reason}")
  done < "${exclusions_file}"
fi

# The reason a migration is excluded, or nothing when it is not excluded.
exclusion_reason_for() {
  local wanted="$1" i
  for i in "${!excluded_files[@]}"; do
    if [ "${excluded_files[$i]}" = "${wanted}" ]; then
      printf '%s' "${excluded_reasons[$i]}"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------- migrations

[ -d "${migrations_dir}" ] || fail "missing migrations directory: ${migrations_dir}"

# The migration files, in lexicographic order. A glob rather than `find`, so
# this works the same on GNU and on BSD.
migration_files=()
while IFS= read -r name; do
  migration_files+=("${name}")
done < <(
  for path in "${migrations_dir}"/*.sql; do
    [ -f "${path}" ] || continue
    printf '%s\n' "${path##*/}"
  done | LC_ALL=C sort
)

[ "${#migration_files[@]}" -gt 0 ] || fail "no .sql file found in ${migrations_dir}"

# A listed exclusion that points at a file which is gone is a stale entry: it
# would hide a migration that nobody looked at any more.
if [ "${#excluded_files[@]}" -gt 0 ]; then
  for file in "${excluded_files[@]}"; do
    found=0
    for candidate in "${migration_files[@]}"; do
      [ "${candidate}" = "${file}" ] && found=1 && break
    done
    [ "${found}" -eq 1 ] \
      || fail "${exclusions_file##*/} lists ${file}, which is not in ${migrations_dir##*/}: remove the stale entry"
  done
fi

total="${#migration_files[@]}"
applied=0
excluded=0
index=0

for file in "${migration_files[@]}"; do
  index=$((index + 1))
  reason="$(exclusion_reason_for "${file}" || true)"
  if [ -n "${reason}" ]; then
    excluded=$((excluded + 1))
    log "SKIPPED ${file} — ${reason}"
    continue
  fi
  log "applying ${index}/${total}: ${file}"
  psql_run --file "${migrations_dir}/${file}" >/dev/null
  applied=$((applied + 1))
done

if [ "$((applied + excluded))" -ne "${total}" ]; then
  fail "internal error: ${applied} applied + ${excluded} excluded != ${total} migrations"
fi

log "done: ${applied} applied, ${excluded} explicitly excluded, ${total} total"
