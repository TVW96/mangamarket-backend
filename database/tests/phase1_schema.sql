-- Local PostgreSQL smoke test for 001_phase1_marketplace.sql
-- Run with: psql -v ON_ERROR_STOP=1 "$DATABASE_URL" -f database/tests/phase1_schema.sql

begin;

insert into public.auth_users (id, email, password_hash)
values
  ('10000000-0000-4000-8000-000000000001', 'developer@example.test', 'test-hash'),
  ('10000000-0000-4000-8000-000000000002', 'seller@example.test', 'test-hash');

insert into public.profiles (id, auth_user_id, username, display_name)
values
  (
    '20000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000001',
    'developer',
    'Developer'
  ),
  (
    '20000000-0000-4000-8000-000000000002',
    '10000000-0000-4000-8000-000000000002',
    'seller',
    'Seller'
  );

insert into public.user_roles (profile_id, role)
values
  ('20000000-0000-4000-8000-000000000001', 'DEVELOPER'),
  ('20000000-0000-4000-8000-000000000002', 'USER');

insert into public.catalog_products (
  id, created_by_profile_id, title, series, volume_number, isbn, language
)
values (
  '30000000-0000-4000-8000-000000000001',
  '20000000-0000-4000-8000-000000000002',
  'Volume One',
  'Example Series',
  1,
  '9780000000001',
  'English'
);

insert into public.inventory_items (
  id, product_id, owner_id, condition, status, acquisition_price
)
values
  (
    '40000000-0000-4000-8000-000000000001',
    '30000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000002',
    'LIKE_NEW',
    'AVAILABLE',
    4.00
  ),
  (
    '40000000-0000-4000-8000-000000000002',
    '30000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000002',
    'GOOD',
    'AVAILABLE',
    3.00
  ),
  (
    '40000000-0000-4000-8000-000000000003',
    '30000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000002',
    'VERY_GOOD',
    'AVAILABLE',
    3.50
  ),
  (
    '40000000-0000-4000-8000-000000000004',
    '30000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000001',
    'GOOD',
    'AVAILABLE',
    2.50
  );

insert into public.listings (
  id, seller_id, type, status, title, price, currency
)
values
  (
    '50000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000002',
    'SINGLE',
    'DRAFT',
    'Single Volume',
    8.00,
    'USD'
  ),
  (
    '50000000-0000-4000-8000-000000000002',
    '20000000-0000-4000-8000-000000000002',
    'BUNDLE',
    'DRAFT',
    'Two-Volume Bundle',
    14.00,
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
  ),
  (
    '50000000-0000-4000-8000-000000000002',
    '40000000-0000-4000-8000-000000000003'
  );

update public.listings
set status = 'ACTIVE'
where id in (
  '50000000-0000-4000-8000-000000000001',
  '50000000-0000-4000-8000-000000000002'
);

-- Cross-seller item attachment is rejected immediately.
do $$
declare
  rejected boolean := false;
begin
  begin
    insert into public.listing_items (listing_id, item_id)
    values (
      '50000000-0000-4000-8000-000000000001',
      '40000000-0000-4000-8000-000000000004'
    );
  exception
    when others then
      if position('owner must match listing seller' in sqlerrm) > 0 then
        rejected := true;
      else
        raise;
      end if;
  end;

  if not rejected then
    raise exception 'Expected cross-seller listing item to be rejected';
  end if;
end;
$$;

-- A second active listing cannot contain the same physical item.
do $$
declare
  rejected boolean := false;
begin
  begin
    insert into public.listings (
      id, seller_id, type, status, title, price, currency
    ) values (
      '50000000-0000-4000-8000-000000000003',
      '20000000-0000-4000-8000-000000000002',
      'SINGLE',
      'DRAFT',
      'Conflicting Listing',
      9.00,
      'USD'
    );

    insert into public.listing_items (listing_id, item_id)
    values (
      '50000000-0000-4000-8000-000000000003',
      '40000000-0000-4000-8000-000000000001'
    );

    update public.listings
    set status = 'ACTIVE'
    where id = '50000000-0000-4000-8000-000000000003';

    set constraints listing_items_exclusivity_after_item immediate;
  exception
    when others then
      if position('multiple active or reserved listings' in sqlerrm) > 0 then
        rejected := true;
      else
        raise;
      end if;
  end;

  if not rejected then
    raise exception 'Expected duplicate active item listing to be rejected';
  end if;
end;
$$;

-- Listing and inventory statuses must be updated together.
do $$
declare
  rejected boolean := false;
begin
  begin
    update public.inventory_items
    set status = 'RESERVED'
    where id = '40000000-0000-4000-8000-000000000001';

    set constraints listing_inventory_state_after_inventory immediate;
  exception
    when others then
      if position('statuses must transition atomically' in sqlerrm) > 0 then
        rejected := true;
      else
        raise;
      end if;
  end;

  if not rejected then
    raise exception 'Expected mismatched listing/inventory status to be rejected';
  end if;
end;
$$;

insert into public.media_assets (
  owner_id, bucket, object_path, original_file_name, media_type,
  mime_type, file_size, alt_text, item_id
)
values (
  '20000000-0000-4000-8000-000000000002',
  'item-media',
  '40000000-0000-4000-8000-000000000001/front.jpg',
  'front.jpg',
  'ITEM',
  'image/jpeg',
  1024,
  'Front cover',
  '40000000-0000-4000-8000-000000000001'
);

do $$
declare
  bundle_item_count integer;
begin
  select count(*)
  into bundle_item_count
  from public.listing_items
  where listing_id = '50000000-0000-4000-8000-000000000002';

  if bundle_item_count <> 2 then
    raise exception 'Expected two listing_items rows for bundle';
  end if;
end;
$$;

select pg_sleep(0.01);
update public.profiles
set display_name = 'Seller Updated'
where id = '20000000-0000-4000-8000-000000000002';

set constraints all immediate;

rollback;
