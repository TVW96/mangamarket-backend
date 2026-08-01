-- Local PostgreSQL smoke test for the Phase 1 baseline and collaborative
-- collector-listing migration.
-- Run with:
--   psql -v ON_ERROR_STOP=1 "$DATABASE_URL" \
--     -f database/tests/phase1_schema.sql

begin;

insert into public.auth_users (id, email, password_hash)
values
  ('10000000-0000-4000-8000-000000000001', 'curator@example.test', 'test-hash'),
  ('10000000-0000-4000-8000-000000000002', 'seller-a@example.test', 'test-hash'),
  ('10000000-0000-4000-8000-000000000003', 'seller-b@example.test', 'test-hash');

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
    'seller_a',
    'Seller A'
  ),
  (
    '20000000-0000-4000-8000-000000000003',
    '10000000-0000-4000-8000-000000000003',
    'seller_b',
    'Seller B'
  );

insert into public.user_roles (profile_id, role)
values
  ('20000000-0000-4000-8000-000000000001', 'DEVELOPER'),
  ('20000000-0000-4000-8000-000000000002', 'USER'),
  ('20000000-0000-4000-8000-000000000003', 'USER');

-- catalog_products is shared bibliographic metadata. Each inventory_items row
-- below is a separately owned physical copy of that product.
insert into public.catalog_products (
  id, created_by_profile_id, title, series, volume_number, isbn, language
)
values (
  '30000000-0000-4000-8000-000000000001',
  '20000000-0000-4000-8000-000000000001',
  'Collector Edition Volume',
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
    '20000000-0000-4000-8000-000000000003',
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

-- One seller's physical copy is offered by itself.
insert into public.listings (
  id, curator_id, type, status, title, price, currency
)
values (
  '50000000-0000-4000-8000-000000000001',
  '20000000-0000-4000-8000-000000000002',
  'SINGLE',
  'DRAFT',
  'Single Physical Copy',
  10.00,
  'USD'
);

insert into public.listing_contributors (
  id, listing_id, seller_id, status, proceeds_amount
)
values (
  '60000000-0000-4000-8000-000000000001',
  '50000000-0000-4000-8000-000000000001',
  '20000000-0000-4000-8000-000000000002',
  'PENDING',
  10.00
);

insert into public.listing_items (
  listing_id, item_id, listing_contributor_id
)
values (
  '50000000-0000-4000-8000-000000000001',
  '40000000-0000-4000-8000-000000000001',
  '60000000-0000-4000-8000-000000000001'
);

update public.listing_contributors lc
set
  status = 'ACCEPTED',
  accepted_terms_version = l.terms_version,
  responded_at = statement_timestamp(),
  accepted_at = statement_timestamp()
from public.listings l
where lc.listing_id = l.id
  and lc.id = '60000000-0000-4000-8000-000000000001';

-- A curator combines physical copies owned by two different sellers. The
-- first copy deliberately overlaps the already-created single listing.
insert into public.listings (
  id, curator_id, type, status, title, price, currency
)
values (
  '50000000-0000-4000-8000-000000000002',
  '20000000-0000-4000-8000-000000000001',
  'BUNDLE',
  'DRAFT',
  'Collaborative Collector Set',
  25.00,
  'USD'
);

insert into public.listing_contributors (
  id, listing_id, seller_id, status, proceeds_amount
)
values
  (
    '60000000-0000-4000-8000-000000000002',
    '50000000-0000-4000-8000-000000000002',
    '20000000-0000-4000-8000-000000000002',
    'PENDING',
    12.00
  ),
  (
    '60000000-0000-4000-8000-000000000003',
    '50000000-0000-4000-8000-000000000002',
    '20000000-0000-4000-8000-000000000003',
    'PENDING',
    13.00
  );

insert into public.listing_items (
  listing_id, item_id, listing_contributor_id
)
values
  (
    '50000000-0000-4000-8000-000000000002',
    '40000000-0000-4000-8000-000000000001',
    '60000000-0000-4000-8000-000000000002'
  ),
  (
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
where lc.listing_id = l.id
  and l.id = '50000000-0000-4000-8000-000000000002';

update public.listings
set status = 'ACTIVE'
where id in (
  '50000000-0000-4000-8000-000000000001',
  '50000000-0000-4000-8000-000000000002'
);

set constraints all immediate;

-- The same still-AVAILABLE physical item may be advertised in multiple
-- ACTIVE listings. The old exclusivity trigger rejected this valid state.
do $$
declare
  active_membership_count integer;
begin
  select count(*)
  into active_membership_count
  from public.listing_items li
  join public.listings l on l.id = li.listing_id
  where li.item_id = '40000000-0000-4000-8000-000000000001'
    and l.status = 'ACTIVE';

  if active_membership_count <> 2 then
    raise exception 'Expected one available physical item in two active listings';
  end if;
end;
$$;

-- The collector set really is cross-seller, not merely curated by a third
-- party around copies from one owner.
do $$
declare
  contributor_count integer;
  owner_count integer;
begin
  select count(*)
  into contributor_count
  from public.listing_contributors
  where listing_id = '50000000-0000-4000-8000-000000000002'
    and status = 'ACCEPTED';

  select count(distinct i.owner_id)
  into owner_count
  from public.listing_items li
  join public.inventory_items i on i.id = li.item_id
  where li.listing_id = '50000000-0000-4000-8000-000000000002';

  if contributor_count <> 2 or owner_count <> 2 then
    raise exception 'Expected two accepted owners in collaborative collector set';
  end if;
end;
$$;

-- A contributor cannot claim another seller's physical item, even in DRAFT.
do $$
declare
  rejected boolean := false;
begin
  begin
    set constraints all deferred;

    insert into public.listings (
      id, curator_id, type, status, title, price, currency
    ) values (
      '50000000-0000-4000-8000-000000000003',
      '20000000-0000-4000-8000-000000000001',
      'SINGLE',
      'DRAFT',
      'Invalid Owner Mapping',
      9.00,
      'USD'
    );

    insert into public.listing_contributors (
      id, listing_id, seller_id, proceeds_amount
    ) values (
      '60000000-0000-4000-8000-000000000004',
      '50000000-0000-4000-8000-000000000003',
      '20000000-0000-4000-8000-000000000003',
      9.00
    );

    insert into public.listing_items (
      listing_id, item_id, listing_contributor_id
    ) values (
      '50000000-0000-4000-8000-000000000003',
      '40000000-0000-4000-8000-000000000003',
      '60000000-0000-4000-8000-000000000004'
    );

    set constraints all immediate;
  exception
    when others then
      if position('contributor is not its current owner' in sqlerrm) > 0 then
        rejected := true;
      else
        raise;
      end if;
  end;

  if not rejected then
    raise exception 'Expected mismatched item owner and contributor to be rejected';
  end if;
end;
$$;

-- A collector set cannot publish until every included owner accepts the exact
-- current terms and their proceeds allocation.
do $$
declare
  rejected boolean := false;
begin
  begin
    set constraints all deferred;

    insert into public.listings (
      id, curator_id, type, status, title, price, currency
    ) values (
      '50000000-0000-4000-8000-000000000004',
      '20000000-0000-4000-8000-000000000001',
      'BUNDLE',
      'DRAFT',
      'Pending Collector Set',
      18.00,
      'USD'
    );

    insert into public.listing_contributors (
      id, listing_id, seller_id, proceeds_amount
    ) values
      (
        '60000000-0000-4000-8000-000000000005',
        '50000000-0000-4000-8000-000000000004',
        '20000000-0000-4000-8000-000000000002',
        8.00
      ),
      (
        '60000000-0000-4000-8000-000000000006',
        '50000000-0000-4000-8000-000000000004',
        '20000000-0000-4000-8000-000000000003',
        10.00
      );

    insert into public.listing_items (
      listing_id, item_id, listing_contributor_id
    ) values
      (
        '50000000-0000-4000-8000-000000000004',
        '40000000-0000-4000-8000-000000000003',
        '60000000-0000-4000-8000-000000000005'
      ),
      (
        '50000000-0000-4000-8000-000000000004',
        '40000000-0000-4000-8000-000000000002',
        '60000000-0000-4000-8000-000000000006'
      );

    update public.listing_contributors lc
    set
      status = 'ACCEPTED',
      accepted_terms_version = l.terms_version,
      responded_at = statement_timestamp(),
      accepted_at = statement_timestamp()
    from public.listings l
    where lc.listing_id = l.id
      and lc.id = '60000000-0000-4000-8000-000000000005';

    update public.listings
    set status = 'ACTIVE'
    where id = '50000000-0000-4000-8000-000000000004';

    set constraints all immediate;
  exception
    when others then
      if position('requires every item-owning contributor to accept current terms and proceeds' in sqlerrm) > 0 then
        rejected := true;
      else
        raise;
      end if;
  end;

  if not rejected then
    raise exception 'Expected pending contributor to block publication';
  end if;
end;
$$;

-- Changing draft terms automatically advances terms_version, so an earlier
-- acceptance cannot be reused against a different price.
do $$
declare
  accepted_version integer;
  revised_version integer;
  rejected boolean := false;
begin
  begin
    set constraints all deferred;

    insert into public.listings (
      id, curator_id, type, status, title, price, currency
    ) values (
      '50000000-0000-4000-8000-000000000005',
      '20000000-0000-4000-8000-000000000001',
      'SINGLE',
      'DRAFT',
      'Terms Version Probe',
      7.00,
      'USD'
    );

    insert into public.listing_contributors (
      id, listing_id, seller_id, proceeds_amount
    ) values (
      '60000000-0000-4000-8000-000000000007',
      '50000000-0000-4000-8000-000000000005',
      '20000000-0000-4000-8000-000000000002',
      7.00
    );

    insert into public.listing_items (
      listing_id, item_id, listing_contributor_id
    ) values (
      '50000000-0000-4000-8000-000000000005',
      '40000000-0000-4000-8000-000000000003',
      '60000000-0000-4000-8000-000000000007'
    );

    select terms_version
    into accepted_version
    from public.listings
    where id = '50000000-0000-4000-8000-000000000005';

    update public.listing_contributors
    set
      status = 'ACCEPTED',
      accepted_terms_version = accepted_version,
      responded_at = statement_timestamp(),
      accepted_at = statement_timestamp()
    where id = '60000000-0000-4000-8000-000000000007';

    update public.listings
    set price = 8.00
    where id = '50000000-0000-4000-8000-000000000005';

    select terms_version
    into revised_version
    from public.listings
    where id = '50000000-0000-4000-8000-000000000005';

    if revised_version <> accepted_version + 1 then
      raise exception 'Expected a material draft edit to advance terms_version';
    end if;

    update public.listings
    set status = 'ACTIVE'
    where id = '50000000-0000-4000-8000-000000000005';

    set constraints all immediate;
  exception
    when others then
      if position('requires every item-owning contributor to accept current terms and proceeds' in sqlerrm) > 0 then
        rejected := true;
      else
        raise;
      end if;
  end;

  if not rejected then
    raise exception 'Expected stale contributor acceptance to block publication';
  end if;
end;
$$;

-- Published material terms cannot be edited in place.
do $$
declare
  rejected boolean := false;
begin
  begin
    update public.listings
    set price = 11.00
    where id = '50000000-0000-4000-8000-000000000001';
  exception
    when others then
      if position('terms are immutable' in sqlerrm) > 0 then
        rejected := true;
      else
        raise;
      end if;
  end;

  if not rejected then
    raise exception 'Expected ACTIVE listing terms to be immutable';
  end if;
end;
$$;

-- Published rows cannot be moved back to DRAFT to bypass immutability.
do $$
declare
  rejected boolean := false;
begin
  begin
    update public.listings
    set status = 'DRAFT'
    where id = '50000000-0000-4000-8000-000000000001';
  exception
    when others then
      if position('Invalid listing lifecycle transition' in sqlerrm) > 0 then
        rejected := true;
      else
        raise;
      end if;
  end;

  if not rejected then
    raise exception 'Expected ACTIVE listing to be unable to return to DRAFT';
  end if;
end;
$$;

-- Published membership and accepted contributor terms are immutable too.
do $$
declare
  membership_rejected boolean := false;
  withdrawal_rejected boolean := false;
begin
  begin
    insert into public.listing_items (
      listing_id, item_id, listing_contributor_id
    ) values (
      '50000000-0000-4000-8000-000000000001',
      '40000000-0000-4000-8000-000000000003',
      '60000000-0000-4000-8000-000000000001'
    );
  exception
    when others then
      if position('composition is immutable' in sqlerrm) > 0 then
        membership_rejected := true;
      else
        raise;
      end if;
  end;

  begin
    set constraints all deferred;

    update public.listing_contributors
    set status = 'WITHDRAWN'
    where id = '60000000-0000-4000-8000-000000000001';

    set constraints all immediate;
  exception
    when others then
      if position('requires every item-owning contributor to accept current terms and proceeds' in sqlerrm) > 0 then
        withdrawal_rejected := true;
      else
        raise;
      end if;
  end;

  if not membership_rejected or not withdrawal_rejected then
    raise exception 'Expected ACTIVE composition mutation and unaccompanied withdrawal to fail';
  end if;
end;
$$;

-- A listing cannot claim SOLD before an order-backed purchase exists.
do $$
declare
  rejected boolean := false;
begin
  begin
    update public.listings
    set status = 'SOLD'
    where id = '50000000-0000-4000-8000-000000000001';
  exception
    when others then
      if position('SOLD requires the Phase 2 order-backed purchase transaction' in sqlerrm) > 0 then
        rejected := true;
      else
        raise;
      end if;
  end;

  if not rejected then
    raise exception 'Expected unbacked Phase 1 SOLD transition to be rejected';
  end if;
end;
$$;

-- Active overlap is intentional, but the same physical copy cannot be held by
-- two reserved offers at once.
do $$
declare
  rejected boolean := false;
begin
  begin
    set constraints all deferred;

    update public.listings
    set status = 'RESERVED'
    where id in (
      '50000000-0000-4000-8000-000000000001',
      '50000000-0000-4000-8000-000000000002'
    );

    update public.inventory_items
    set status = 'RESERVED'
    where id in (
      '40000000-0000-4000-8000-000000000001',
      '40000000-0000-4000-8000-000000000002'
    );

    set constraints all immediate;
  exception
    when others then
      if position('cannot appear in more than one RESERVED listing' in sqlerrm) > 0 then
        rejected := true;
      else
        raise;
      end if;
  end;

  if not rejected then
    raise exception 'Expected duplicate reservation of one physical item to be rejected';
  end if;
end;
$$;

do $$
declare
  rejected boolean := false;
begin
  begin
    update public.inventory_items
    set status = 'RESERVED'
    where id = '40000000-0000-4000-8000-000000000001';
  exception
    when others then
      if position('matching AVAILABLE/RESERVED inventory state' in sqlerrm) > 0 then
        rejected := true;
      else
        raise;
      end if;
  end;

  if not rejected then
    raise exception 'Expected non-atomic inventory reservation to be rejected';
  end if;
end;
$$;

-- SOLD also remains unavailable for an otherwise unlisted physical item until
-- the Phase 2 order-backed purchase transaction exists.
do $$
declare
  rejected boolean := false;
begin
  begin
    update public.inventory_items
    set status = 'SOLD'
    where id = '40000000-0000-4000-8000-000000000004';
  exception
    when others then
      if position('SOLD requires the Phase 2 order-backed purchase transaction' in sqlerrm) > 0 then
        rejected := true;
      else
        raise;
      end if;
  end;

  if not rejected then
    raise exception 'Expected unbacked physical-item SOLD transition to be rejected';
  end if;
end;
$$;

-- The reservation-side transition succeeds when the winning offer, physical
-- item, and every competing offer move together in one deferred transaction.
set constraints all deferred;

update public.listing_contributors
set status = 'WITHDRAWN'
where id = '60000000-0000-4000-8000-000000000003';

update public.listings
set
  status = 'ARCHIVED',
  invalidated_at = statement_timestamp(),
  invalidation_reason = 'CONTRIBUTOR_WITHDREW'
where id = '50000000-0000-4000-8000-000000000002';

update public.listings
set status = 'RESERVED'
where id = '50000000-0000-4000-8000-000000000001';

update public.inventory_items
set status = 'RESERVED'
where id = '40000000-0000-4000-8000-000000000001';

set constraints all immediate;

do $$
begin
  if not exists (
    select 1
    from public.listings winner
    join public.inventory_items item
      on item.id = '40000000-0000-4000-8000-000000000001'
    where winner.id = '50000000-0000-4000-8000-000000000001'
      and winner.status = 'RESERVED'
      and item.status = 'RESERVED'
  ) or not exists (
    select 1
    from public.listings
    where id = '50000000-0000-4000-8000-000000000002'
      and status = 'ARCHIVED'
  ) then
    raise exception 'Expected atomic winner reservation and competitor archival';
  end if;
end;
$$;

-- Archival preserves an immutable offer/contributor snapshot. A later owner
-- transfer is allowed without rewriting who contributed the historical item.
do $$
declare
  lifecycle_rejected boolean := false;
  terms_rejected boolean := false;
  metadata_rejected boolean := false;
  membership_rejected boolean := false;
  contributor_rejected boolean := false;
begin
  begin
    update public.listings
    set status = 'ACTIVE'
    where id = '50000000-0000-4000-8000-000000000002';
  exception
    when others then
      if position('Invalid listing lifecycle transition' in sqlerrm) > 0 then
        lifecycle_rejected := true;
      else
        raise;
      end if;
  end;

  begin
    update public.listings
    set price = 26.00
    where id = '50000000-0000-4000-8000-000000000002';
  exception
    when others then
      if position('Non-DRAFT listing' in sqlerrm) > 0 then
        terms_rejected := true;
      else
        raise;
      end if;
  end;

  begin
    update public.listings
    set invalidation_reason = 'REWRITTEN_HISTORY'
    where id = '50000000-0000-4000-8000-000000000002';
  exception
    when others then
      if position('history metadata is immutable' in sqlerrm) > 0 then
        metadata_rejected := true;
      else
        raise;
      end if;
  end;

  begin
    delete from public.listing_items
    where listing_id = '50000000-0000-4000-8000-000000000002'
      and item_id = '40000000-0000-4000-8000-000000000002';
  exception
    when others then
      if position('Non-DRAFT listing' in sqlerrm) > 0 then
        membership_rejected := true;
      else
        raise;
      end if;
  end;

  begin
    update public.listing_contributors
    set status = 'WITHDRAWN',
        accepted_terms_version = null,
        responded_at = statement_timestamp(),
        accepted_at = null
    where id = '60000000-0000-4000-8000-000000000003';
  exception
    when others then
      if position('Non-DRAFT listing' in sqlerrm) > 0 then
        contributor_rejected := true;
      else
        raise;
      end if;
  end;

  if not lifecycle_rejected
     or not terms_rejected
     or not metadata_rejected
     or not membership_rejected
     or not contributor_rejected then
    raise exception 'Expected archived listing history to be immutable and terminal';
  end if;
end;
$$;

update public.inventory_items
set owner_id = '20000000-0000-4000-8000-000000000001'
where id = '40000000-0000-4000-8000-000000000002';

set constraints all immediate;

do $$
begin
  if not exists (
    select 1
    from public.listing_items li
    join public.listing_contributors lc
      on lc.id = li.listing_contributor_id
     and lc.listing_id = li.listing_id
    join public.inventory_items i on i.id = li.item_id
    where li.listing_id = '50000000-0000-4000-8000-000000000002'
      and li.item_id = '40000000-0000-4000-8000-000000000002'
      and lc.seller_id = '20000000-0000-4000-8000-000000000003'
      and lc.status = 'WITHDRAWN'
      and lc.accepted_terms_version is not null
      and lc.responded_at is not null
      and lc.accepted_at is not null
      and i.owner_id = '20000000-0000-4000-8000-000000000001'
  ) then
    raise exception 'Expected archived contributor snapshot to survive later ownership transfer';
  end if;
end;
$$;

-- New listings must begin as drafts; publication is a separate validated
-- lifecycle transition.
do $$
declare
  rejected boolean := false;
begin
  begin
    insert into public.listings (
      id, curator_id, type, status, title, price, currency
    ) values (
      '50000000-0000-4000-8000-000000000006',
      '20000000-0000-4000-8000-000000000001',
      'SINGLE',
      'ACTIVE',
      'Invalid Direct Publication',
      5.00,
      'USD'
    );
  exception
    when others then
      if position('A new listing must start in DRAFT' in sqlerrm) > 0 then
        rejected := true;
      else
        raise;
      end if;
  end;

  if not rejected then
    raise exception 'Expected non-DRAFT listing insertion to be rejected';
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

-- Preserve explicit coverage that timestamp maintenance advances updated_at.
create temporary table profile_update_probe as
select id, updated_at
from public.profiles
where id = '20000000-0000-4000-8000-000000000002';

select pg_sleep(0.01);
update public.profiles
set display_name = 'Seller A Updated'
where id = '20000000-0000-4000-8000-000000000002';

do $$
begin
  if not exists (
    select 1
    from public.profiles p
    join profile_update_probe probe on probe.id = p.id
    where p.updated_at > probe.updated_at
  ) then
    raise exception 'Expected updated_at trigger to advance the timestamp';
  end if;
end;
$$;

set constraints all immediate;

rollback;
