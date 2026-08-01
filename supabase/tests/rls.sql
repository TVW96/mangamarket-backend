-- Run after `supabase db reset` with `supabase test db`.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(44);

insert into auth.users (id, email)
values
  ('10000000-0000-4000-8000-000000000001', 'curator@example.test'),
  ('10000000-0000-4000-8000-000000000002', 'seller@example.test'),
  ('10000000-0000-4000-8000-000000000003', 'seller-c@example.test'),
  ('10000000-0000-4000-8000-000000000004', 'outsider@example.test');

insert into public.profiles (id, auth_user_id, username, display_name)
values
  (
    '20000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000001',
    'curator',
    'Collector Curator'
  ),
  (
    '20000000-0000-4000-8000-000000000002',
    '10000000-0000-4000-8000-000000000002',
    'seller_b',
    'Seller B'
  ),
  (
    '20000000-0000-4000-8000-000000000003',
    '10000000-0000-4000-8000-000000000003',
    'seller_c',
    'Seller C'
  ),
  (
    '20000000-0000-4000-8000-000000000004',
    '10000000-0000-4000-8000-000000000004',
    'outsider',
    'Outsider'
  );

insert into public.user_roles (profile_id, role)
values
  ('20000000-0000-4000-8000-000000000001', 'USER'),
  ('20000000-0000-4000-8000-000000000002', 'USER'),
  ('20000000-0000-4000-8000-000000000003', 'USER'),
  ('20000000-0000-4000-8000-000000000004', 'USER');

insert into public.catalog_products (
  id, created_by_profile_id, title, series, volume_number, isbn, language
)
values
  (
    '30000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000001',
    'Collector Volume One',
    'Collector Series',
    1,
    '9780000000001',
    'English'
  ),
  (
    '30000000-0000-4000-8000-000000000002',
    '20000000-0000-4000-8000-000000000002',
    'Collector Volume Two',
    'Collector Series',
    2,
    '9780000000002',
    'English'
  ),
  (
    '30000000-0000-4000-8000-000000000003',
    '20000000-0000-4000-8000-000000000003',
    'Collector Volume Three',
    'Collector Series',
    3,
    '9780000000003',
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
    'Curator private note',
    'AVAILABLE',
    4.00
  ),
  (
    '40000000-0000-4000-8000-000000000002',
    '30000000-0000-4000-8000-000000000002',
    '20000000-0000-4000-8000-000000000002',
    'GOOD',
    'Seller B private note',
    'AVAILABLE',
    5.00
  ),
  (
    '40000000-0000-4000-8000-000000000003',
    '30000000-0000-4000-8000-000000000003',
    '20000000-0000-4000-8000-000000000003',
    'VERY_GOOD',
    'Seller C private note',
    'AVAILABLE',
    6.00
  );

-- Seed two actionable listings that deliberately share Seller B's one physical
-- copy. This is the intended overlapping-offer behavior while it is AVAILABLE.
insert into public.listings (
  id, curator_id, type, status, title, price, currency
)
values
  (
    '50000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000001',
    'BUNDLE',
    'DRAFT',
    'Collaborative Collector Bundle',
    30.00,
    'USD'
  ),
  (
    '50000000-0000-4000-8000-000000000002',
    '20000000-0000-4000-8000-000000000002',
    'SINGLE',
    'DRAFT',
    'Seller B Single',
    18.00,
    'USD'
  ),
  (
    '50000000-0000-4000-8000-000000000003',
    '20000000-0000-4000-8000-000000000001',
    'SINGLE',
    'DRAFT',
    'Proposed Shared Single',
    18.00,
    'USD'
  );

insert into public.listing_contributors (
  id, listing_id, seller_id, status, proceeds_amount
)
values
  (
    '60000000-0000-4000-8000-000000000001',
    '50000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000001',
    'PENDING',
    12.00
  ),
  (
    '60000000-0000-4000-8000-000000000002',
    '50000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000002',
    'PENDING',
    18.00
  ),
  (
    '60000000-0000-4000-8000-000000000003',
    '50000000-0000-4000-8000-000000000002',
    '20000000-0000-4000-8000-000000000002',
    'PENDING',
    18.00
  );

insert into public.listing_items (
  id, listing_id, item_id, listing_contributor_id
)
values
  (
    '70000000-0000-4000-8000-000000000001',
    '50000000-0000-4000-8000-000000000001',
    '40000000-0000-4000-8000-000000000001',
    '60000000-0000-4000-8000-000000000001'
  ),
  (
    '70000000-0000-4000-8000-000000000002',
    '50000000-0000-4000-8000-000000000001',
    '40000000-0000-4000-8000-000000000002',
    '60000000-0000-4000-8000-000000000002'
  ),
  (
    '70000000-0000-4000-8000-000000000003',
    '50000000-0000-4000-8000-000000000002',
    '40000000-0000-4000-8000-000000000002',
    '60000000-0000-4000-8000-000000000003'
  );

update public.listing_contributors lc
set
  status = 'ACCEPTED',
  accepted_terms_version = l.terms_version,
  responded_at = statement_timestamp(),
  accepted_at = statement_timestamp()
from public.listings l
where l.id = lc.listing_id;

update public.listings
set status = 'ACTIVE'
where id in (
  '50000000-0000-4000-8000-000000000001',
  '50000000-0000-4000-8000-000000000002'
);

set constraints all immediate;
set constraints all deferred;

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-4000-8000-000000000001',
  true
);

select hasnt_column(
  'public', 'public_profiles', 'auth_user_id',
  'Public profile projection omits the private authentication identifier'
);

select hasnt_column(
  'public', 'marketplace_inventory_items', 'acquisition_price',
  'Marketplace inventory projection omits acquisition price'
);

select hasnt_column(
  'public', 'marketplace_inventory_items', 'condition_notes',
  'Marketplace inventory projection omits private condition notes'
);

select is(
  (select count(*)::integer from public.profiles),
  1,
  'Authenticated profile base reads are limited to the current owner'
);

select is(
  (select count(*)::integer from public.public_profiles),
  4,
  'Safe public profile projection exposes marketplace identities'
);

select is(
  (
    select count(*)::integer
    from public.inventory_items
    where id = '40000000-0000-4000-8000-000000000001'
      and acquisition_price = 4.00
  ),
  1,
  'Owner can read their own private inventory fields'
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
  'Marketplace projection exposes another seller available physical item'
);

select is(
  has_column_privilege('authenticated', 'public.listings', 'status', 'UPDATE'),
  false,
  'Authenticated clients cannot directly update listing lifecycle status'
);

select is(
  has_column_privilege('authenticated', 'public.listings', 'price', 'UPDATE'),
  false,
  'Authenticated clients cannot bypass the draft-terms RPC with raw price updates'
);

select is(
  has_column_privilege('authenticated', 'public.listing_items', 'listing_id', 'INSERT'),
  false,
  'Authenticated clients cannot directly insert listing membership'
);

select is(
  has_column_privilege('authenticated', 'public.listing_contributors', 'status', 'UPDATE'),
  false,
  'Authenticated clients cannot directly forge contribution responses'
);

select is(
  (
    select count(distinct l.id)::integer
    from public.listings l
    join public.listing_items li on li.listing_id = l.id
    where li.item_id = '40000000-0000-4000-8000-000000000002'
      and l.status = 'ACTIVE'
  ),
  2,
  'The same AVAILABLE physical item may appear in multiple ACTIVE listings'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-4000-8000-000000000004',
  true
);

select is(
  (select count(*)::integer from public.listings where status = 'ACTIVE'),
  2,
  'An unrelated authenticated user can read public ACTIVE listings'
);

select is(
  (
    select count(*)::integer
    from public.listings
    where id = '50000000-0000-4000-8000-000000000003'
  ),
  0,
  'An unrelated user cannot read another curator draft'
);

select is(
  (select count(*)::integer from public.listing_contributors),
  0,
  'Consent and proposed proceeds are hidden from nonparticipants'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-4000-8000-000000000001',
  true
);

select lives_ok(
  $$
    select public.propose_listing_item(
      '50000000-0000-4000-8000-000000000003',
      '40000000-0000-4000-8000-000000000002',
      18.00
    )
  $$,
  'Curator can atomically propose another seller available item'
);

select is(
  (
    select seller_id::text || ':' || status::text
    from public.listing_contributors
    where listing_id = '50000000-0000-4000-8000-000000000003'
  ),
  '20000000-0000-4000-8000-000000000002:PENDING',
  'Proposal derives a pending contributor from the physical item owner'
);

select is(
  (
    select count(*)::integer
    from public.listings
    where id = '50000000-0000-4000-8000-000000000003'
  ),
  1,
  'Curator can read their own collaborative draft'
);

select throws_ok(
  $$
    insert into public.listing_items (
      listing_id, item_id, listing_contributor_id
    ) values (
      '50000000-0000-4000-8000-000000000003',
      '40000000-0000-4000-8000-000000000001',
      (
        select id
        from public.listing_contributors
        where listing_id = '50000000-0000-4000-8000-000000000003'
      )
    )
  $$,
  '42501',
  null,
  'Curator cannot bypass the safe proposal RPC with raw membership INSERT'
);

select throws_ok(
  $$
    select public.respond_to_listing_contribution(
      (
        select id
        from public.listing_contributors
        where listing_id = '50000000-0000-4000-8000-000000000003'
      ),
      'ACCEPTED'
    )
  $$,
  '42501',
  null,
  'Curator cannot accept another seller contribution'
);

select lives_ok(
  $$
    select public.update_draft_contributor_proceeds(
      '50000000-0000-4000-8000-000000000003',
      (
        select id
        from public.listing_contributors
        where listing_id = '50000000-0000-4000-8000-000000000003'
      ),
      17.00
    )
  $$,
  'Curator can revise proposed contributor proceeds through the safe RPC'
);

select is(
  (
    select proceeds_amount::text || ':' || status::text
    from public.listing_contributors
    where listing_id = '50000000-0000-4000-8000-000000000003'
  ),
  '17.00:PENDING',
  'Revised proceeds reset that seller consent to PENDING'
);

select lives_ok(
  $$
    select public.update_draft_listing(
      '50000000-0000-4000-8000-000000000003',
      'SINGLE',
      'Proposed Shared Single Revised',
      'One physical copy may participate in several offers.',
      17.00,
      'USD'
    )
  $$,
  'Curator can revise material draft terms through the advisory-first RPC'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-4000-8000-000000000002',
  true
);

select is(
  (
    select count(*)::integer
    from public.listings
    where id = '50000000-0000-4000-8000-000000000003'
  ),
  1,
  'A contributing seller can read the draft in which they participate'
);

select is(
  (
    select count(*)::integer
    from public.listing_contributors
    where listing_id = '50000000-0000-4000-8000-000000000003'
  ),
  1,
  'A participant can read consent and proceeds for their collaborative draft'
);

select lives_ok(
  $$
    select public.respond_to_listing_contribution(
      (
        select id
        from public.listing_contributors
        where listing_id = '50000000-0000-4000-8000-000000000003'
      ),
      'ACCEPTED'
    )
  $$,
  'Current physical-item seller can accept the current proposal terms'
);

select is(
  (
    select lc.accepted_terms_version = l.terms_version
    from public.listing_contributors lc
    join public.listings l on l.id = lc.listing_id
    where lc.listing_id = '50000000-0000-4000-8000-000000000003'
  ),
  true,
  'Seller acceptance records the exact current terms version'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-4000-8000-000000000001',
  true
);

select lives_ok(
  $$
    select public.publish_listing('50000000-0000-4000-8000-000000000003')
  $$,
  'Curator can publish after every current owner accepts current terms'
);

select is(
  (
    select count(distinct l.id)::integer
    from public.listings l
    join public.listing_items li on li.listing_id = l.id
    where li.item_id = '40000000-0000-4000-8000-000000000002'
      and l.status = 'ACTIVE'
  ),
  3,
  'A physical item may remain in three ACTIVE offers before any reservation'
);

select throws_ok(
  $$
    select public.update_draft_listing(
      '50000000-0000-4000-8000-000000000003',
      'SINGLE',
      'Tampered Active Title',
      null,
      17.00,
      'USD'
    )
  $$,
  '23514',
  null,
  'Published terms cannot be edited in place'
);

select throws_ok(
  $$
    select public.remove_listing_item(
      '50000000-0000-4000-8000-000000000003',
      (
        select id
        from public.listing_items
        where listing_id = '50000000-0000-4000-8000-000000000003'
      )
    )
  $$,
  '23514',
  null,
  'Published composition cannot be edited in place'
);

select is(
  public.can_manage_storage_path(
    'listing-media',
    '50000000-0000-4000-8000-000000000003/cover.jpg'
  ),
  true,
  'Listing curator controls its Storage path'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-4000-8000-000000000002',
  true
);

select is(
  public.can_manage_storage_path(
    'listing-media',
    '50000000-0000-4000-8000-000000000003/cover.jpg'
  ),
  false,
  'Item contributor cannot overwrite curator-controlled listing media'
);

select lives_ok(
  $$
    select public.respond_to_listing_contribution(
      (
        select id
        from public.listing_contributors
        where listing_id = '50000000-0000-4000-8000-000000000003'
      ),
      'WITHDRAWN'
    )
  $$,
  'Current seller may withdraw by atomically archiving the actionable listing'
);

select is(
  (
    select status::text
    from public.listings
    where id = '50000000-0000-4000-8000-000000000003'
  ),
  'ARCHIVED',
  'Actionable seller withdrawal archives the listing'
);

select is(
  (
    select
      status = 'WITHDRAWN'
      and accepted_terms_version is not null
      and accepted_at is not null
    from public.listing_contributors
    where listing_id = '50000000-0000-4000-8000-000000000003'
  ),
  true,
  'Withdrawal preserves the published acceptance snapshot as history'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-4000-8000-000000000004',
  true
);

select is(
  (
    select count(*)::integer
    from public.listings
    where id = '50000000-0000-4000-8000-000000000003'
  ),
  0,
  'Archived listing is no longer publicly readable'
);

reset role;

select throws_ok(
  $$
    update public.listings
    set status = 'SOLD'
    where id = '50000000-0000-4000-8000-000000000001'
  $$,
  '23514',
  'SOLD requires the Phase 2 order-backed purchase transaction',
  'Phase 1 rejects fabricated listing purchase completion'
);

select throws_ok(
  $$
    update public.inventory_items
    set status = 'SOLD'
    where id = '40000000-0000-4000-8000-000000000002'
  $$,
  '23514',
  'SOLD requires the Phase 2 order-backed purchase transaction',
  'Phase 1 rejects fabricated inventory sale completion'
);

select throws_ok(
  $test$
    do $block$
    begin
      update public.inventory_items
      set status = 'RESERVED'
      where id = '40000000-0000-4000-8000-000000000002';

      set constraints all immediate;
    end;
    $block$
  $test$,
  '23514',
  null,
  'Inventory state cannot change while overlapping ACTIVE listings remain actionable'
);

select throws_ok(
  $$
    update public.listings
    set status = 'DRAFT'
    where id = '50000000-0000-4000-8000-000000000003'
  $$,
  '23514',
  null,
  'Terminal listing history cannot be reopened as a draft'
);

-- Prepare two more overlapping ACTIVE offers for one Seller C item. Both are
-- valid while AVAILABLE, but a transaction may reserve at most one of them.
insert into public.listings (
  id, curator_id, type, status, title, price, currency
)
values
  (
    '50000000-0000-4000-8000-000000000004',
    '20000000-0000-4000-8000-000000000003',
    'SINGLE',
    'DRAFT',
    'Seller C Offer One',
    9.00,
    'USD'
  ),
  (
    '50000000-0000-4000-8000-000000000005',
    '20000000-0000-4000-8000-000000000003',
    'SINGLE',
    'DRAFT',
    'Seller C Offer Two',
    9.00,
    'USD'
  );

insert into public.listing_contributors (
  id, listing_id, seller_id, status, proceeds_amount
)
values
  (
    '60000000-0000-4000-8000-000000000004',
    '50000000-0000-4000-8000-000000000004',
    '20000000-0000-4000-8000-000000000003',
    'PENDING',
    9.00
  ),
  (
    '60000000-0000-4000-8000-000000000005',
    '50000000-0000-4000-8000-000000000005',
    '20000000-0000-4000-8000-000000000003',
    'PENDING',
    9.00
  );

insert into public.listing_items (
  id, listing_id, item_id, listing_contributor_id
)
values
  (
    '70000000-0000-4000-8000-000000000004',
    '50000000-0000-4000-8000-000000000004',
    '40000000-0000-4000-8000-000000000003',
    '60000000-0000-4000-8000-000000000004'
  ),
  (
    '70000000-0000-4000-8000-000000000005',
    '50000000-0000-4000-8000-000000000005',
    '40000000-0000-4000-8000-000000000003',
    '60000000-0000-4000-8000-000000000005'
  );

update public.listing_contributors lc
set
  status = 'ACCEPTED',
  accepted_terms_version = l.terms_version,
  responded_at = statement_timestamp(),
  accepted_at = statement_timestamp()
from public.listings l
where l.id = lc.listing_id
  and l.id in (
    '50000000-0000-4000-8000-000000000004',
    '50000000-0000-4000-8000-000000000005'
  );

update public.listings
set status = 'ACTIVE'
where id in (
  '50000000-0000-4000-8000-000000000004',
  '50000000-0000-4000-8000-000000000005'
);

set constraints all immediate;
set constraints all deferred;

select is(
  (
    select count(*)::integer
    from public.listings l
    join public.listing_items li on li.listing_id = l.id
    where li.item_id = '40000000-0000-4000-8000-000000000003'
      and l.status = 'ACTIVE'
  ),
  2,
  'Two ACTIVE listings may overlap on one AVAILABLE Seller C item'
);

select throws_ok(
  $test$
    do $block$
    begin
      update public.inventory_items
      set status = 'RESERVED'
      where id = '40000000-0000-4000-8000-000000000003';

      update public.listings
      set status = 'RESERVED'
      where id in (
        '50000000-0000-4000-8000-000000000004',
        '50000000-0000-4000-8000-000000000005'
      );

      set constraints all immediate;
    end;
    $block$
  $test$,
  '23514',
  null,
  'One physical item cannot be reserved by two listings'
);

select * from finish();
rollback;
