-- MangaMarketplace Supabase security and Storage overlay
-- Applies after 20260731120000_schema.sql.

begin;

create or replace function public.current_profile_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select p.id
  from public.profiles p
  where p.auth_user_id = (select auth.uid())
$$;

create or replace function public.is_privileged()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.user_roles ur
    join public.profiles p on p.id = ur.profile_id
    where p.auth_user_id = (select auth.uid())
      and ur.role in ('DEVELOPER', 'ADMIN')
  )
$$;

create or replace function public.safe_uuid(value text)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
begin
  return value::uuid;
exception
  when invalid_text_representation then
    return null;
end;
$$;

create or replace function public.can_manage_media_target(
  target_owner_id uuid,
  target_media_type public.media_type,
  target_product_id uuid,
  target_item_id uuid,
  target_listing_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_privileged()
    or (
      target_owner_id = public.current_profile_id()
      and case target_media_type
        when 'AVATAR' then true
        when 'PRODUCT' then exists (
          select 1
          from public.catalog_products p
          where p.id = target_product_id
            and p.created_by_profile_id = public.current_profile_id()
            and p.deleted_at is null
        )
        when 'ITEM' then exists (
          select 1
          from public.inventory_items i
          where i.id = target_item_id
            and i.owner_id = public.current_profile_id()
            and i.deleted_at is null
        )
        when 'LISTING' then exists (
          select 1
          from public.listings l
          where l.id = target_listing_id
            and l.seller_id = public.current_profile_id()
            and l.deleted_at is null
        )
        else false
      end
    )
$$;

create or replace function public.can_read_media_asset(
  target_owner_id uuid,
  target_media_type public.media_type,
  target_product_id uuid,
  target_item_id uuid,
  target_listing_id uuid,
  target_deleted_at timestamptz
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select target_owner_id = public.current_profile_id()
    or public.is_privileged()
    or (
      target_deleted_at is null
      and case target_media_type
        when 'AVATAR' then true
        when 'PRODUCT' then exists (
          select 1
          from public.catalog_products p
          where p.id = target_product_id and p.deleted_at is null
        )
        when 'ITEM' then exists (
          select 1
          from public.inventory_items i
          where i.id = target_item_id
            and i.status = 'AVAILABLE'
            and i.deleted_at is null
        )
        when 'LISTING' then exists (
          select 1
          from public.listings l
          where l.id = target_listing_id
            and l.status = 'ACTIVE'
            and l.deleted_at is null
        )
        else false
      end
    )
$$;

alter table public.profiles enable row level security;
alter table public.user_roles enable row level security;
alter table public.catalog_products enable row level security;
alter table public.inventory_items enable row level security;
alter table public.listings enable row level security;
alter table public.listing_items enable row level security;
alter table public.media_assets enable row level security;

-- Explicit grants keep private seller fields off the anonymous API.
revoke all on table public.profiles from anon, authenticated;
revoke all on table public.user_roles from anon, authenticated;
revoke all on table public.catalog_products from anon, authenticated;
revoke all on table public.inventory_items from anon, authenticated;
revoke all on table public.listings from anon, authenticated;
revoke all on table public.listing_items from anon, authenticated;
revoke all on table public.media_assets from anon, authenticated;

grant select on table public.profiles to anon, authenticated;
grant insert (auth_user_id, username, display_name, bio, avatar_path)
  on table public.profiles to authenticated;
grant update (username, display_name, bio, avatar_path)
  on table public.profiles to authenticated;

grant select, insert, update, delete
  on table public.user_roles to authenticated;

grant select on table public.catalog_products to anon, authenticated;
grant insert (
  created_by_profile_id, title, series, volume_number, edition, isbn,
  author, publisher, language, publication_date
) on table public.catalog_products to authenticated;
grant update (
  title, series, volume_number, edition, isbn, author, publisher,
  language, publication_date, deleted_at
) on table public.catalog_products to authenticated;

grant select on table public.inventory_items to authenticated;
grant insert (
  product_id, owner_id, condition, condition_notes, status, acquisition_price
) on table public.inventory_items to authenticated;
grant update (
  condition, condition_notes, status, acquisition_price, deleted_at
) on table public.inventory_items to authenticated;

grant select on table public.listings to anon, authenticated;
grant insert (
  seller_id, type, status, title, description, price, currency
) on table public.listings to authenticated;
grant update (
  type, status, title, description, price, currency, sold_at, deleted_at
) on table public.listings to authenticated;

grant select on table public.listing_items to anon, authenticated;
grant insert (listing_id, item_id, quantity)
  on table public.listing_items to authenticated;
grant delete on table public.listing_items to authenticated;

grant select on table public.media_assets to anon, authenticated;
grant insert (
  owner_id, bucket, object_path, original_file_name, media_type, mime_type,
  file_size, alt_text, product_id, item_id, listing_id
) on table public.media_assets to authenticated;
grant update (alt_text, deleted_at)
  on table public.media_assets to authenticated;

create policy profiles_public_read
on public.profiles
for select
to anon, authenticated
using (true);

create policy profiles_owner_insert
on public.profiles
for insert
to authenticated
with check (auth_user_id = (select auth.uid()));

create policy profiles_owner_update
on public.profiles
for update
to authenticated
using (auth_user_id = (select auth.uid()) or public.is_privileged())
with check (auth_user_id = (select auth.uid()) or public.is_privileged());

create policy roles_self_read
on public.user_roles
for select
to authenticated
using (profile_id = public.current_profile_id() or public.is_privileged());

create policy roles_privileged_insert
on public.user_roles
for insert
to authenticated
with check (public.is_privileged());

create policy roles_privileged_update
on public.user_roles
for update
to authenticated
using (public.is_privileged())
with check (public.is_privileged());

create policy roles_privileged_delete
on public.user_roles
for delete
to authenticated
using (public.is_privileged());

create policy catalog_products_public_read
on public.catalog_products
for select
to anon, authenticated
using (
  deleted_at is null
  or created_by_profile_id = public.current_profile_id()
  or public.is_privileged()
);

create policy catalog_products_owner_insert
on public.catalog_products
for insert
to authenticated
with check (
  created_by_profile_id = public.current_profile_id()
  or public.is_privileged()
);

create policy catalog_products_owner_update
on public.catalog_products
for update
to authenticated
using (
  created_by_profile_id = public.current_profile_id()
  or public.is_privileged()
)
with check (
  created_by_profile_id = public.current_profile_id()
  or public.is_privileged()
);

-- Base inventory reads are owner/privileged only because acquisition_price and
-- condition_notes are private. Public consumers use marketplace_inventory_items.
create policy inventory_items_private_read
on public.inventory_items
for select
to authenticated
using (owner_id = public.current_profile_id() or public.is_privileged());

create policy inventory_items_owner_insert
on public.inventory_items
for insert
to authenticated
with check (owner_id = public.current_profile_id() or public.is_privileged());

create policy inventory_items_owner_update
on public.inventory_items
for update
to authenticated
using (owner_id = public.current_profile_id() or public.is_privileged())
with check (owner_id = public.current_profile_id() or public.is_privileged());

create policy listings_public_or_owner_read
on public.listings
for select
to anon, authenticated
using (
  (status = 'ACTIVE' and deleted_at is null)
  or seller_id = public.current_profile_id()
  or public.is_privileged()
);

create policy listings_owner_insert
on public.listings
for insert
to authenticated
with check (seller_id = public.current_profile_id() or public.is_privileged());

create policy listings_owner_update
on public.listings
for update
to authenticated
using (seller_id = public.current_profile_id() or public.is_privileged())
with check (seller_id = public.current_profile_id() or public.is_privileged());

create policy listing_items_public_or_owner_read
on public.listing_items
for select
to anon, authenticated
using (
  exists (
    select 1
    from public.listings l
    where l.id = listing_id
      and (
        (l.status = 'ACTIVE' and l.deleted_at is null)
        or l.seller_id = public.current_profile_id()
        or public.is_privileged()
      )
  )
);

create policy listing_items_owner_insert
on public.listing_items
for insert
to authenticated
with check (
  public.is_privileged()
  or exists (
    select 1
    from public.listings l
    join public.inventory_items i on i.id = item_id
    where l.id = listing_id
      and l.status = 'DRAFT'
      and l.deleted_at is null
      and l.seller_id = public.current_profile_id()
      and i.owner_id = public.current_profile_id()
      and i.deleted_at is null
  )
);

create policy listing_items_owner_delete_draft
on public.listing_items
for delete
to authenticated
using (
  public.is_privileged()
  or exists (
    select 1
    from public.listings l
    where l.id = listing_id
      and l.status = 'DRAFT'
      and l.seller_id = public.current_profile_id()
  )
);

create policy media_assets_visible_read
on public.media_assets
for select
to anon, authenticated
using (
  public.can_read_media_asset(
    owner_id, media_type, product_id, item_id, listing_id, deleted_at
  )
);

create policy media_assets_owner_insert
on public.media_assets
for insert
to authenticated
with check (
  public.can_manage_media_target(
    owner_id, media_type, product_id, item_id, listing_id
  )
);

create policy media_assets_owner_update
on public.media_assets
for update
to authenticated
using (owner_id = public.current_profile_id() or public.is_privileged())
with check (
  public.can_manage_media_target(
    owner_id, media_type, product_id, item_id, listing_id
  )
);

-- This intentionally security-definer view exposes only marketplace-safe
-- inventory columns. The sensitive base table remains owner-only.
create or replace view public.marketplace_inventory_items
with (security_barrier = true)
as
select
  i.id,
  i.product_id,
  i.owner_id,
  i.condition,
  i.status,
  i.created_at,
  i.updated_at
from public.inventory_items i
where i.status = 'AVAILABLE'
  and i.deleted_at is null;

revoke all on table public.marketplace_inventory_items from public;
grant select on table public.marketplace_inventory_items to anon, authenticated;

-- Private Storage buckets require RLS-authorized reads or signed URLs.
insert into storage.buckets (id, name, public)
values
  ('avatars', 'avatars', false),
  ('product-media', 'product-media', false),
  ('item-media', 'item-media', false),
  ('listing-media', 'listing-media', false)
on conflict (id) do update set public = excluded.public;

create or replace function public.can_manage_storage_path(
  target_bucket text,
  target_name text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_privileged()
    or case target_bucket
      when 'avatars' then
        public.safe_uuid((storage.foldername(target_name))[1])
          = public.current_profile_id()
      when 'product-media' then exists (
        select 1
        from public.catalog_products p
        where p.id = public.safe_uuid((storage.foldername(target_name))[1])
          and p.created_by_profile_id = public.current_profile_id()
          and p.deleted_at is null
      )
      when 'item-media' then exists (
        select 1
        from public.inventory_items i
        where i.id = public.safe_uuid((storage.foldername(target_name))[1])
          and i.owner_id = public.current_profile_id()
          and i.deleted_at is null
      )
      when 'listing-media' then exists (
        select 1
        from public.listings l
        where l.id = public.safe_uuid((storage.foldername(target_name))[1])
          and l.seller_id = public.current_profile_id()
          and l.deleted_at is null
      )
      else false
    end
$$;

create or replace function public.can_read_storage_path(
  target_bucket text,
  target_name text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_privileged()
    or case target_bucket
      when 'avatars' then exists (
        select 1
        from public.profiles p
        where p.id = public.safe_uuid((storage.foldername(target_name))[1])
      )
      when 'product-media' then exists (
        select 1
        from public.catalog_products p
        where p.id = public.safe_uuid((storage.foldername(target_name))[1])
          and (
            p.deleted_at is null
            or p.created_by_profile_id = public.current_profile_id()
          )
      )
      when 'item-media' then exists (
        select 1
        from public.inventory_items i
        where i.id = public.safe_uuid((storage.foldername(target_name))[1])
          and (
            (i.status = 'AVAILABLE' and i.deleted_at is null)
            or i.owner_id = public.current_profile_id()
          )
      )
      when 'listing-media' then exists (
        select 1
        from public.listings l
        where l.id = public.safe_uuid((storage.foldername(target_name))[1])
          and (
            (l.status = 'ACTIVE' and l.deleted_at is null)
            or l.seller_id = public.current_profile_id()
          )
      )
      else false
    end
$$;

drop policy if exists manga_storage_read on storage.objects;
drop policy if exists manga_storage_insert on storage.objects;
drop policy if exists manga_storage_update on storage.objects;
drop policy if exists manga_storage_delete on storage.objects;

create policy manga_storage_read
on storage.objects
for select
to anon, authenticated
using (public.can_read_storage_path(bucket_id, name));

create policy manga_storage_insert
on storage.objects
for insert
to authenticated
with check (public.can_manage_storage_path(bucket_id, name));

create policy manga_storage_update
on storage.objects
for update
to authenticated
using (public.can_manage_storage_path(bucket_id, name))
with check (public.can_manage_storage_path(bucket_id, name));

create policy manga_storage_delete
on storage.objects
for delete
to authenticated
using (public.can_manage_storage_path(bucket_id, name));

revoke all on function public.current_profile_id() from public;
revoke all on function public.is_privileged() from public;
revoke all on function public.safe_uuid(text) from public;
revoke all on function public.can_manage_media_target(
  uuid, public.media_type, uuid, uuid, uuid
) from public;
revoke all on function public.can_read_media_asset(
  uuid, public.media_type, uuid, uuid, uuid, timestamptz
) from public;
revoke all on function public.can_manage_storage_path(text, text) from public;
revoke all on function public.can_read_storage_path(text, text) from public;

grant execute on function public.current_profile_id() to anon, authenticated;
grant execute on function public.is_privileged() to anon, authenticated;
grant execute on function public.safe_uuid(text) to anon, authenticated;
grant execute on function public.can_manage_media_target(
  uuid, public.media_type, uuid, uuid, uuid
) to authenticated;
grant execute on function public.can_read_media_asset(
  uuid, public.media_type, uuid, uuid, uuid, timestamptz
) to anon, authenticated;
grant execute on function public.can_manage_storage_path(text, text)
  to authenticated;
grant execute on function public.can_read_storage_path(text, text)
  to anon, authenticated;

commit;
