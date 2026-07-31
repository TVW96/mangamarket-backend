-- MangaMarketplace canonical Phase 1 schema - local PostgreSQL deployment
-- PostgreSQL 15+
--
-- Shared domain tables match the Supabase deployment. The intentional
-- deployment difference is authentication: local profiles reference
-- public.auth_users; Supabase profiles reference auth.users.

begin;

create schema if not exists extensions;
create extension if not exists citext with schema extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm with schema extensions;

create type public.user_role_name as enum (
  'USER',
  'DEVELOPER',
  'ADMIN'
);

create type public.inventory_status as enum (
  'AVAILABLE',
  'RESERVED',
  'SOLD',
  'REMOVED'
);

create type public.item_condition as enum (
  'NEW',
  'LIKE_NEW',
  'VERY_GOOD',
  'GOOD',
  'ACCEPTABLE',
  'POOR'
);

create type public.listing_type as enum (
  'SINGLE',
  'BUNDLE'
);

create type public.listing_status as enum (
  'DRAFT',
  'ACTIVE',
  'RESERVED',
  'SOLD',
  'CANCELLED',
  'ARCHIVED'
);

create type public.media_type as enum (
  'AVATAR',
  'PRODUCT',
  'ITEM',
  'LISTING'
);

create table public.auth_users (
  id uuid primary key default gen_random_uuid(),
  email extensions.citext not null,
  password_hash text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint auth_users_email_unique unique (email),
  constraint auth_users_email_not_blank check (btrim(email::text) <> ''),
  constraint auth_users_password_hash_not_blank
    check (btrim(password_hash) <> '')
);

create table public.profiles (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null,
  username extensions.citext not null,
  display_name text,
  bio text,
  avatar_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_auth_user_unique unique (auth_user_id),
  constraint profiles_username_unique unique (username),
  constraint profiles_username_not_blank check (btrim(username::text) <> ''),
  constraint profiles_auth_user_fk
    foreign key (auth_user_id)
    references public.auth_users (id)
    on delete restrict
);

create table public.user_roles (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null,
  role public.user_role_name not null default 'USER',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint user_roles_profile_role_unique unique (profile_id, role),
  constraint user_roles_profile_fk
    foreign key (profile_id)
    references public.profiles (id)
    on delete restrict
);

create table public.catalog_products (
  id uuid primary key default gen_random_uuid(),
  created_by_profile_id uuid,
  title text not null,
  series text,
  volume_number numeric(6, 2),
  edition text,
  isbn text,
  author text,
  publisher text,
  language text not null,
  publication_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint catalog_products_title_not_blank check (btrim(title) <> ''),
  constraint catalog_products_language_not_blank check (btrim(language) <> ''),
  constraint catalog_products_volume_nonnegative
    check (volume_number is null or volume_number >= 0),
  constraint catalog_products_isbn_unique unique (isbn),
  constraint catalog_products_creator_fk
    foreign key (created_by_profile_id)
    references public.profiles (id)
    on delete set null
);

create table public.inventory_items (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null,
  owner_id uuid not null,
  condition public.item_condition not null,
  condition_notes text,
  status public.inventory_status not null default 'AVAILABLE',
  acquisition_price numeric(12, 2),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint inventory_items_acquisition_price_nonnegative
    check (acquisition_price is null or acquisition_price >= 0),
  constraint inventory_items_product_fk
    foreign key (product_id)
    references public.catalog_products (id)
    on delete restrict,
  constraint inventory_items_owner_fk
    foreign key (owner_id)
    references public.profiles (id)
    on delete restrict
);

create table public.listings (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null,
  type public.listing_type not null,
  status public.listing_status not null default 'DRAFT',
  title text not null,
  description text,
  price numeric(12, 2) not null,
  currency char(3) not null default 'USD',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  sold_at timestamptz,
  deleted_at timestamptz,
  constraint listings_title_not_blank check (btrim(title) <> ''),
  constraint listings_price_positive check (price > 0),
  constraint listings_currency_iso_shape check (currency ~ '^[A-Z]{3}$'),
  constraint listings_sold_at_matches_status
    check (sold_at is null or status = 'SOLD'),
  constraint listings_seller_fk
    foreign key (seller_id)
    references public.profiles (id)
    on delete restrict
);

create table public.listing_items (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null,
  item_id uuid not null,
  quantity integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint listing_items_quantity_one check (quantity = 1),
  constraint listing_items_listing_item_unique unique (listing_id, item_id),
  constraint listing_items_listing_fk
    foreign key (listing_id)
    references public.listings (id)
    on delete restrict,
  constraint listing_items_inventory_item_fk
    foreign key (item_id)
    references public.inventory_items (id)
    on delete restrict
);

create table public.media_assets (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null,
  bucket text not null,
  object_path text not null,
  original_file_name text not null,
  media_type public.media_type not null,
  mime_type text not null,
  file_size bigint not null,
  alt_text text,
  product_id uuid,
  item_id uuid,
  listing_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint media_assets_storage_object_unique unique (bucket, object_path),
  constraint media_assets_bucket_not_blank check (btrim(bucket) <> ''),
  constraint media_assets_object_path_not_blank check (btrim(object_path) <> ''),
  constraint media_assets_original_file_name_not_blank
    check (btrim(original_file_name) <> ''),
  constraint media_assets_mime_type_not_blank check (btrim(mime_type) <> ''),
  constraint media_assets_file_size_positive check (file_size > 0),
  constraint media_assets_supported_parent check (
    (media_type = 'AVATAR'
      and product_id is null and item_id is null and listing_id is null)
    or
    (media_type = 'PRODUCT'
      and product_id is not null and item_id is null and listing_id is null)
    or
    (media_type = 'ITEM'
      and product_id is null and item_id is not null and listing_id is null)
    or
    (media_type = 'LISTING'
      and product_id is null and item_id is null and listing_id is not null)
  ),
  constraint media_assets_bucket_and_path_match_type check (
    (media_type = 'AVATAR'
      and bucket = 'avatars'
      and split_part(object_path, '/', 1) = owner_id::text)
    or
    (media_type = 'PRODUCT'
      and bucket = 'product-media'
      and split_part(object_path, '/', 1) = product_id::text)
    or
    (media_type = 'ITEM'
      and bucket = 'item-media'
      and split_part(object_path, '/', 1) = item_id::text)
    or
    (media_type = 'LISTING'
      and bucket = 'listing-media'
      and split_part(object_path, '/', 1) = listing_id::text)
  ),
  constraint media_assets_owner_fk
    foreign key (owner_id)
    references public.profiles (id)
    on delete restrict,
  constraint media_assets_product_fk
    foreign key (product_id)
    references public.catalog_products (id)
    on delete restrict,
  constraint media_assets_inventory_item_fk
    foreign key (item_id)
    references public.inventory_items (id)
    on delete restrict,
  constraint media_assets_listing_fk
    foreign key (listing_id)
    references public.listings (id)
    on delete restrict
);

-- Access-pattern indexes.
create index user_roles_role_idx on public.user_roles (role);

create index catalog_products_series_volume_idx
  on public.catalog_products (lower(series), volume_number)
  where series is not null and deleted_at is null;
create index catalog_products_language_idx
  on public.catalog_products (lower(language))
  where deleted_at is null;
create index catalog_products_title_trgm_idx
  on public.catalog_products using gin
  (lower(title) extensions.gin_trgm_ops)
  where deleted_at is null;
create index catalog_products_series_trgm_idx
  on public.catalog_products using gin
  (lower(series) extensions.gin_trgm_ops)
  where series is not null and deleted_at is null;
create index catalog_products_publisher_trgm_idx
  on public.catalog_products using gin
  (lower(publisher) extensions.gin_trgm_ops)
  where publisher is not null and deleted_at is null;
create index catalog_products_author_trgm_idx
  on public.catalog_products using gin
  (lower(author) extensions.gin_trgm_ops)
  where author is not null and deleted_at is null;

create index inventory_items_owner_status_idx
  on public.inventory_items (owner_id, status)
  where deleted_at is null;
create index inventory_items_product_idx
  on public.inventory_items (product_id)
  where deleted_at is null;
create index inventory_items_condition_idx
  on public.inventory_items (condition)
  where deleted_at is null;

create index listings_active_created_idx
  on public.listings (created_at desc)
  where status = 'ACTIVE' and deleted_at is null;
create index listings_seller_created_idx
  on public.listings (seller_id, created_at desc)
  where deleted_at is null;
create index listings_filter_idx
  on public.listings (status, type, price)
  where deleted_at is null;

create index listing_items_item_idx on public.listing_items (item_id);

create index media_assets_owner_created_idx
  on public.media_assets (owner_id, created_at desc)
  where deleted_at is null;
create index media_assets_product_idx
  on public.media_assets (product_id)
  where product_id is not null and deleted_at is null;
create index media_assets_item_idx
  on public.media_assets (item_id)
  where item_id is not null and deleted_at is null;
create index media_assets_listing_idx
  on public.media_assets (listing_id)
  where listing_id is not null and deleted_at is null;

-- Shared timestamp maintenance.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = statement_timestamp();
  return new;
end;
$$;

create trigger auth_users_set_updated_at
before update on public.auth_users
for each row execute function public.set_updated_at();

create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

create trigger user_roles_set_updated_at
before update on public.user_roles
for each row execute function public.set_updated_at();

create trigger catalog_products_set_updated_at
before update on public.catalog_products
for each row execute function public.set_updated_at();

create trigger inventory_items_set_updated_at
before update on public.inventory_items
for each row execute function public.set_updated_at();

create trigger listings_set_updated_at
before update on public.listings
for each row execute function public.set_updated_at();

create trigger listing_items_set_updated_at
before update on public.listing_items
for each row execute function public.set_updated_at();

create trigger media_assets_set_updated_at
before update on public.media_assets
for each row execute function public.set_updated_at();

-- A listing may only reference inventory owned by its seller.
create or replace function public.validate_listing_item_owner()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  listing_seller_id uuid;
  inventory_owner_id uuid;
begin
  select seller_id
  into listing_seller_id
  from public.listings
  where id = new.listing_id;

  select owner_id
  into inventory_owner_id
  from public.inventory_items
  where id = new.item_id;

  if listing_seller_id is null or inventory_owner_id is null then
    raise exception 'Listing and inventory item must exist';
  end if;

  if listing_seller_id <> inventory_owner_id then
    raise exception 'Inventory item owner must match listing seller';
  end if;

  return new;
end;
$$;

create trigger listing_items_validate_owner
before insert or update of listing_id, item_id on public.listing_items
for each row execute function public.validate_listing_item_owner();

-- Validate SINGLE/BUNDLE cardinality at transaction commit. DRAFT and
-- CANCELLED listings may be incomplete; publishable and historical states may not.
create or replace function public.enforce_listing_cardinality()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  target_listing_id uuid;
  target_type public.listing_type;
  target_status public.listing_status;
  item_count integer;
begin
  if tg_table_name = 'listings' then
    target_listing_id := case when tg_op = 'DELETE' then old.id else new.id end;
  else
    target_listing_id := case
      when tg_op = 'DELETE' then old.listing_id
      else new.listing_id
    end;
  end if;

  select type, status
  into target_type, target_status
  from public.listings
  where id = target_listing_id;

  if not found or target_status in ('DRAFT', 'CANCELLED') then
    return null;
  end if;

  select count(*)
  into item_count
  from public.listing_items
  where listing_id = target_listing_id;

  if target_type = 'SINGLE' and item_count <> 1 then
    raise exception 'SINGLE listing must contain exactly one inventory item';
  end if;

  if target_type = 'BUNDLE' and item_count < 2 then
    raise exception 'BUNDLE listing must contain at least two inventory items';
  end if;

  return null;
end;
$$;

create constraint trigger listings_cardinality_after_listing
after insert or update of type, status on public.listings
deferrable initially deferred
for each row execute function public.enforce_listing_cardinality();

create constraint trigger listings_cardinality_after_item
after insert or update or delete on public.listing_items
deferrable initially deferred
for each row execute function public.enforce_listing_cardinality();

-- Prevent one physical inventory item from appearing in multiple active or
-- reserved listings. Advisory locks serialize competing item activations.
create or replace function public.enforce_item_listing_exclusivity()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  target_item_id uuid;
  active_listing_count integer;
begin
  if tg_table_name = 'listing_items' then
    target_item_id := case when tg_op = 'DELETE' then old.item_id else new.item_id end;

    perform pg_advisory_xact_lock(hashtextextended(target_item_id::text, 0));

    select count(distinct l.id)
    into active_listing_count
    from public.listing_items li
    join public.listings l on l.id = li.listing_id
    where li.item_id = target_item_id
      and l.status in ('ACTIVE', 'RESERVED')
      and l.deleted_at is null;

    if active_listing_count > 1 then
      raise exception 'Inventory item cannot appear in multiple active or reserved listings';
    end if;
  else
    for target_item_id in
      select li.item_id
      from public.listing_items li
      where li.listing_id = new.id
      order by li.item_id
    loop
      perform pg_advisory_xact_lock(hashtextextended(target_item_id::text, 0));

      select count(distinct l.id)
      into active_listing_count
      from public.listing_items li
      join public.listings l on l.id = li.listing_id
      where li.item_id = target_item_id
        and l.status in ('ACTIVE', 'RESERVED')
        and l.deleted_at is null;

      if active_listing_count > 1 then
        raise exception 'Inventory item cannot appear in multiple active or reserved listings';
      end if;
    end loop;
  end if;

  return null;
end;
$$;

create constraint trigger listing_items_exclusivity_after_item
after insert or update of listing_id, item_id or delete on public.listing_items
deferrable initially deferred
for each row execute function public.enforce_item_listing_exclusivity();

create constraint trigger listing_items_exclusivity_after_listing
after update of status, deleted_at on public.listings
deferrable initially deferred
for each row execute function public.enforce_item_listing_exclusivity();

-- Listing and inventory state must be changed in one transaction.
create or replace function public.enforce_listing_inventory_state()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  target_listing_id uuid;
  target_status public.listing_status;
  invalid_count integer;
begin
  if tg_table_name = 'listings' then
    target_listing_id := case when tg_op = 'DELETE' then old.id else new.id end;
  elsif tg_table_name = 'listing_items' then
    target_listing_id := case
      when tg_op = 'DELETE' then old.listing_id
      else new.listing_id
    end;
  else
    for target_listing_id in
      select li.listing_id
      from public.listing_items li
      where li.item_id = case when tg_op = 'DELETE' then old.id else new.id end
    loop
      perform public.assert_listing_inventory_state(target_listing_id);
    end loop;
    return null;
  end if;

  select status into target_status
  from public.listings
  where id = target_listing_id;

  if not found or target_status not in ('ACTIVE', 'RESERVED', 'SOLD') then
    return null;
  end if;

  select count(*)
  into invalid_count
  from public.listing_items li
  join public.inventory_items i on i.id = li.item_id
  where li.listing_id = target_listing_id
    and (
      (target_status = 'ACTIVE' and i.status <> 'AVAILABLE')
      or (target_status = 'RESERVED' and i.status <> 'RESERVED')
      or (target_status = 'SOLD' and i.status <> 'SOLD')
    );

  if invalid_count > 0 then
    raise exception 'Listing and inventory statuses must transition atomically';
  end if;

  return null;
end;
$$;

-- Helper used by inventory-row deferred triggers.
create or replace function public.assert_listing_inventory_state(target_listing_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  target_status public.listing_status;
  invalid_count integer;
begin
  select status into target_status
  from public.listings
  where id = target_listing_id;

  if not found or target_status not in ('ACTIVE', 'RESERVED', 'SOLD') then
    return;
  end if;

  select count(*)
  into invalid_count
  from public.listing_items li
  join public.inventory_items i on i.id = li.item_id
  where li.listing_id = target_listing_id
    and (
      (target_status = 'ACTIVE' and i.status <> 'AVAILABLE')
      or (target_status = 'RESERVED' and i.status <> 'RESERVED')
      or (target_status = 'SOLD' and i.status <> 'SOLD')
    );

  if invalid_count > 0 then
    raise exception 'Listing and inventory statuses must transition atomically';
  end if;
end;
$$;

create constraint trigger listing_inventory_state_after_listing
after insert or update of status on public.listings
deferrable initially deferred
for each row execute function public.enforce_listing_inventory_state();

create constraint trigger listing_inventory_state_after_item
after insert or update or delete on public.listing_items
deferrable initially deferred
for each row execute function public.enforce_listing_inventory_state();

create constraint trigger listing_inventory_state_after_inventory
after update of status on public.inventory_items
deferrable initially deferred
for each row execute function public.enforce_listing_inventory_state();

comment on table public.auth_users is
  'Local authentication adapter. Supabase deployments use auth.users instead.';
comment on column public.inventory_items.acquisition_price is
  'Seller-private acquisition cost; never expose in public marketplace reads.';
comment on column public.inventory_items.condition_notes is
  'Seller-authored notes; expose publicly only through an explicitly safe API projection.';

commit;
