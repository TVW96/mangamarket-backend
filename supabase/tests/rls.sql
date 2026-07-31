-- Run after `supabase db reset` with `supabase test db`.

begin;

create extension if not exists pgtap with schema extensions;
select plan(18);

insert into auth.users (id, email)
values
  ('10000000-0000-4000-8000-000000000001', 'owner-a@example.test'),
  ('10000000-0000-4000-8000-000000000002', 'owner-b@example.test'),
  ('10000000-0000-4000-8000-000000000003', 'developer@example.test');

insert into public.profiles (id, auth_user_id, username, display_name)
values
  (
    '20000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000001',
    'owner_a',
    'Owner A'
  ),
  (
    '20000000-0000-4000-8000-000000000002',
    '10000000-0000-4000-8000-000000000002',
    'owner_b',
    'Owner B'
  ),
  (
    '20000000-0000-4000-8000-000000000003',
    '10000000-0000-4000-8000-000000000003',
    'developer',
    'Developer'
  );

insert into public.user_roles (profile_id, role)
values
  ('20000000-0000-4000-8000-000000000001', 'USER'),
  ('20000000-0000-4000-8000-000000000002', 'USER'),
  ('20000000-0000-4000-8000-000000000003', 'DEVELOPER');

insert into public.catalog_products (
  id, created_by_profile_id, title, series, volume_number, isbn, language
)
values
  (
    '30000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000001',
    'Owner A Volume',
    'Test Series',
    1,
    '9780000000001',
    'English'
  ),
  (
    '30000000-0000-4000-8000-000000000002',
    '20000000-0000-4000-8000-000000000002',
    'Owner B Volume',
    'Test Series',
    2,
    '9780000000002',
    'English'
  );

insert into public.inventory_items (
  id, product_id, owner_id, condition, condition_notes,
  status, acquisition_price
)
values
  (
    '40000000-0000-4000-8000-000000000001',
    '30000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000001',
    'LIKE_NEW',
    'Owner A private note',
    'AVAILABLE',
    4.00
  ),
  (
    '40000000-0000-4000-8000-000000000002',
    '30000000-0000-4000-8000-000000000002',
    '20000000-0000-4000-8000-000000000002',
    'GOOD',
    'Owner B private note',
    'AVAILABLE',
    5.00
  );

insert into public.listings (
  id, seller_id, type, status, title, price, currency
)
values
  (
    '50000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000001',
    'SINGLE',
    'DRAFT',
    'Owner A Listing',
    10.00,
    'USD'
  ),
  (
    '50000000-0000-4000-8000-000000000002',
    '20000000-0000-4000-8000-000000000002',
    'SINGLE',
    'DRAFT',
    'Owner B Listing',
    11.00,
    'USD'
  );

insert into public.listing_items (listing_id, item_id)
values
  (
    '50000000-0000-4000-8000-000000000001',
    '40000000-0000-4000-8000-000000000001'
  ),
  (
    '50000000-0000-4000-8000-000000000002',
    '40000000-0000-4000-8000-000000000002'
  );

update public.listings
set status = 'ACTIVE'
where id = '50000000-0000-4000-8000-000000000002';

set constraints all immediate;

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-4000-8000-000000000001',
  true
);

select hasnt_column(
  'public', 'profiles', 'email',
  'Public profiles do not duplicate authentication email'
);

select is(
  (select count(*)::integer from public.profiles),
  3,
  'Authenticated users can read public profiles'
);

select lives_ok(
  $$
    update public.profiles
    set display_name = 'Owner A Updated'
    where id = '20000000-0000-4000-8000-000000000001'
  $$,
  'Owner can update own profile'
);

select lives_ok(
  $$
    update public.profiles
    set display_name = 'Compromised'
    where id = '20000000-0000-4000-8000-000000000002'
  $$,
  'Cross-profile update is safely filtered by RLS'
);

select is(
  (
    select display_name
    from public.profiles
    where id = '20000000-0000-4000-8000-000000000002'
  ),
  'Owner B',
  'Cross-profile update changed no data'
);

select throws_ok(
  $$
    insert into public.user_roles (profile_id, role)
    values ('20000000-0000-4000-8000-000000000001', 'ADMIN')
  $$,
  '42501',
  null,
  'Regular user cannot self-assign ADMIN'
);

select is(
  (
    select count(*)::integer
    from public.inventory_items
    where id = '40000000-0000-4000-8000-000000000001'
      and acquisition_price = 4.00
  ),
  1,
  'Owner can read own private acquisition price'
);

select is(
  (
    select count(*)::integer
    from public.inventory_items
    where id = '40000000-0000-4000-8000-000000000002'
  ),
  0,
  'Owner cannot read another seller private inventory row'
);

select is(
  (
    select count(*)::integer
    from public.marketplace_inventory_items
    where id = '40000000-0000-4000-8000-000000000002'
  ),
  1,
  'Marketplace-safe view exposes another seller available item'
);

select hasnt_column(
  'public', 'marketplace_inventory_items', 'acquisition_price',
  'Marketplace-safe view omits acquisition price'
);

select hasnt_column(
  'public', 'marketplace_inventory_items', 'condition_notes',
  'Marketplace-safe view omits private condition notes'
);

select is(
  (
    select count(*)::integer
    from public.listings
    where id = '50000000-0000-4000-8000-000000000002'
  ),
  1,
  'Active listing is publicly readable'
);

select lives_ok(
  $$
    update public.listings
    set title = 'Compromised Listing'
    where id = '50000000-0000-4000-8000-000000000002'
  $$,
  'Cross-listing update is safely filtered by RLS'
);

select is(
  (
    select title
    from public.listings
    where id = '50000000-0000-4000-8000-000000000002'
  ),
  'Owner B Listing',
  'Cross-listing update changed no data'
);

select is(
  public.can_manage_storage_path(
    'item-media',
    '40000000-0000-4000-8000-000000000001/front.jpg'
  ),
  true,
  'Owner can manage own item media path'
);

select is(
  public.can_manage_storage_path(
    'item-media',
    '40000000-0000-4000-8000-000000000002/front.jpg'
  ),
  false,
  'Owner cannot manage another seller item media path'
);

select throws_ok(
  $$
    insert into public.media_assets (
      owner_id, bucket, object_path, original_file_name, media_type,
      mime_type, file_size, item_id
    ) values (
      '20000000-0000-4000-8000-000000000001',
      'item-media',
      '40000000-0000-4000-8000-000000000002/front.jpg',
      'front.jpg',
      'ITEM',
      'image/jpeg',
      1024,
      '40000000-0000-4000-8000-000000000001'
    )
  $$,
  '23514',
  null,
  'Media path must match its target resource ID'
);

select is(
  public.safe_uuid('not-a-uuid'),
  null,
  'Malformed Storage paths fail closed instead of raising'
);

select * from finish();
rollback;
