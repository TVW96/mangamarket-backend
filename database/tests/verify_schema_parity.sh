#!/usr/bin/env bash

set -euo pipefail

: "${LOCAL_DATABASE_URL:?Set LOCAL_DATABASE_URL to the local PostgreSQL database}"
: "${SUPABASE_DATABASE_URL:?Set SUPABASE_DATABASE_URL to the Supabase database}"

parity_tmp_dir="$(mktemp -d)"
trap 'rm -rf "$parity_tmp_dir"' EXIT

shared_tables="'profiles','user_roles','catalog_products','inventory_items','listings','listing_contributors','listing_items','media_assets'"

enums_query="
select
  t.typname,
  e.enumsortorder,
  e.enumlabel
from pg_type t
join pg_enum e on e.enumtypid = t.oid
join pg_namespace n on n.oid = t.typnamespace
where n.nspname = 'public'
order by t.typname, e.enumsortorder;
"

columns_query="
select
  table_name,
  column_name,
  data_type,
  udt_schema,
  udt_name,
  is_nullable,
  coalesce(column_default, '')
from information_schema.columns
where table_schema = 'public'
  and table_name in (${shared_tables})
order by table_name, ordinal_position;
"

constraints_query="
select
  c.conrelid::regclass::text,
  c.conname,
  c.contype,
  pg_get_constraintdef(c.oid, true)
from pg_constraint c
join pg_class t on t.oid = c.conrelid
join pg_namespace n on n.oid = t.relnamespace
where n.nspname = 'public'
  and t.relname in (${shared_tables})
  and c.conname <> 'profiles_auth_user_fk'
order by 1, 2;
"

indexes_query="
select tablename, indexname, indexdef
from pg_indexes
where schemaname = 'public'
  and tablename in (${shared_tables})
order by tablename, indexname;
"

triggers_query="
select
  c.relname,
  tr.tgname,
  tr.tgdeferrable,
  tr.tginitdeferred,
  pg_get_triggerdef(tr.oid, true)
from pg_trigger tr
join pg_class c on c.oid = tr.tgrelid
join pg_namespace n on n.oid = c.relnamespace
where not tr.tgisinternal
  and n.nspname = 'public'
  and c.relname in (${shared_tables})
order by c.relname, tr.tgname;
"

routines_query="
with shared_trigger_functions as (
  select distinct tr.tgfoid
  from pg_trigger tr
  join pg_class c on c.oid = tr.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where not tr.tgisinternal
    and n.nspname = 'public'
    and c.relname in (${shared_tables})
)
select
  p.proname,
  pg_get_function_identity_arguments(p.oid),
  pg_get_functiondef(p.oid)
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and (
    p.oid in (select tgfoid from shared_trigger_functions)
    or p.proname in (
      'lock_collaborative_listing_set',
      'validate_collaborative_listing'
    )
  )
order by p.proname, pg_get_function_identity_arguments(p.oid);
"

compare_query() {
  local label="$1"
  local query="$2"

  psql "$LOCAL_DATABASE_URL" -X -A -t -F '|' -v ON_ERROR_STOP=1 \
    -c "$query" > "$parity_tmp_dir/local-${label}.txt"
  psql "$SUPABASE_DATABASE_URL" -X -A -t -F '|' -v ON_ERROR_STOP=1 \
    -c "$query" > "$parity_tmp_dir/supabase-${label}.txt"

  diff -u \
    "$parity_tmp_dir/local-${label}.txt" \
    "$parity_tmp_dir/supabase-${label}.txt"
}

compare_query enums "$enums_query"
compare_query columns "$columns_query"
compare_query constraints "$constraints_query"
compare_query indexes "$indexes_query"
compare_query triggers "$triggers_query"
compare_query routines "$routines_query"

echo "Shared MangaMarketplace schemas match."
