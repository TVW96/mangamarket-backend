-- Local-only validation harness for Supabase migrations.
-- Do not deploy this file to Supabase. Real Supabase projects already provide
-- these roles, schemas, tables, and helper functions.

create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;

create schema auth;
create table auth.users (
  id uuid primary key,
  email text unique
);

create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

create schema storage;
create table storage.buckets (
  id text primary key,
  name text not null,
  public boolean not null default false
);

create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text not null references storage.buckets (id),
  name text not null,
  owner_id text
);

alter table storage.objects enable row level security;

create or replace function storage.foldername(name text)
returns text[]
language sql
immutable
as $$
  select case
    when array_length(string_to_array(name, '/'), 1) <= 1 then array[]::text[]
    else (string_to_array(name, '/'))[
      1:array_length(string_to_array(name, '/'), 1) - 1
    ]
  end
$$;

grant usage on schema auth, storage to anon, authenticated;
grant select, insert, update, delete on storage.objects to anon, authenticated;
