-- MangaMarketplace Phase 1 collaborative collector listings - Supabase.
--
-- A listing is curated by one profile but may contain physical inventory
-- contributed by several sellers. The same AVAILABLE physical inventory item
-- may intentionally appear in more than one ACTIVE listing. Checkout,
-- reservation ownership, payments, and payout snapshots remain Phase 2 work.

begin;

create type public.listing_contributor_status as enum (
  'PENDING',
  'ACCEPTED',
  'REJECTED',
  'WITHDRAWN'
);

-- The creator organizes the offer; item ownership and proposed seller proceeds
-- are represented independently by listing_contributors.
alter table public.listings
  rename column seller_id to curator_id;

alter table public.listings
  rename constraint listings_seller_fk to listings_curator_fk;

alter index public.listings_seller_created_idx
  rename to listings_curator_created_idx;

alter table public.listings
  add column terms_version integer not null default 1,
  add column invalidated_at timestamptz,
  add column invalidation_reason text,
  add constraint listings_terms_version_positive
    check (terms_version > 0),
  add constraint listings_invalidation_pair
    check (
      (invalidated_at is null and invalidation_reason is null)
      or
      (
        invalidated_at is not null
        and invalidation_reason is not null
        and btrim(invalidation_reason) <> ''
      )
    );

create table public.listing_contributors (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null,
  seller_id uuid not null,
  status public.listing_contributor_status not null default 'PENDING',
  accepted_terms_version integer,
  proceeds_amount numeric(12, 2),
  responded_at timestamptz,
  accepted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint listing_contributors_listing_seller_unique
    unique (listing_id, seller_id),
  constraint listing_contributors_id_listing_unique
    unique (id, listing_id),
  constraint listing_contributors_accepted_terms_version_positive
    check (
      accepted_terms_version is null
      or accepted_terms_version > 0
    ),
  constraint listing_contributors_proceeds_nonnegative
    check (proceeds_amount is null or proceeds_amount >= 0),
  constraint listing_contributors_response_shape
    check (
      (
        status = 'PENDING'
        and accepted_terms_version is null
        and responded_at is null
        and accepted_at is null
      )
      or
      (
        status = 'ACCEPTED'
        and accepted_terms_version is not null
        and responded_at is not null
        and accepted_at is not null
      )
      or
      (
        status = 'REJECTED'
        and accepted_terms_version is null
        and responded_at is not null
        and accepted_at is null
      )
      or
      (
        status = 'WITHDRAWN'
        and responded_at is not null
        and (
          (
            accepted_terms_version is null
            and accepted_at is null
          )
          or
          (
            accepted_terms_version is not null
            and accepted_at is not null
          )
        )
      )
    ),
  constraint listing_contributors_listing_fk
    foreign key (listing_id)
    references public.listings (id)
    on delete restrict,
  constraint listing_contributors_seller_fk
    foreign key (seller_id)
    references public.profiles (id)
    on delete restrict
);

create index listing_contributors_listing_status_idx
  on public.listing_contributors (listing_id, status);
create index listing_contributors_seller_status_idx
  on public.listing_contributors (seller_id, status);

alter table public.listing_items
  add column listing_contributor_id uuid;

-- Rows created under the original single-seller rule have exactly one seller
-- per listing. Preserve them as accepted contributions at terms version 1.
insert into public.listing_contributors (
  listing_id,
  seller_id,
  status,
  accepted_terms_version,
  proceeds_amount,
  responded_at,
  accepted_at
)
select
  l.id,
  i.owner_id,
  'ACCEPTED'::public.listing_contributor_status,
  l.terms_version,
  l.price,
  statement_timestamp(),
  statement_timestamp()
from public.listings l
join public.listing_items li on li.listing_id = l.id
join public.inventory_items i on i.id = li.item_id
group by l.id, i.owner_id, l.terms_version, l.price
on conflict (listing_id, seller_id) do nothing;

update public.listing_items li
set listing_contributor_id = lc.id
from public.inventory_items i,
     public.listing_contributors lc
where i.id = li.item_id
  and lc.listing_id = li.listing_id
  and lc.seller_id = i.owner_id;

do $$
begin
  if exists (
    select 1
    from public.listing_items
    where listing_contributor_id is null
  ) then
    raise exception using
      errcode = '23514',
      message = 'Every listing item must resolve to its physical-item owner contributor';
  end if;
end;
$$;

-- The backfill UPDATE queues the baseline migration's deferred listing-item
-- triggers. Flush those events before altering listing_items, then restore the
-- migration's deferred mode. Existing baseline rows already satisfy the old
-- same-seller/cardinality/state rules.
set constraints all immediate;
set constraints all deferred;

alter table public.listing_items
  alter column listing_contributor_id set not null,
  add constraint listing_items_contributor_listing_fk
    foreign key (listing_contributor_id, listing_id)
    references public.listing_contributors (id, listing_id)
    on delete restrict;

create index listing_items_contributor_idx
  on public.listing_items (listing_contributor_id);

create trigger listing_contributors_set_updated_at
before update on public.listing_contributors
for each row execute function public.set_updated_at();

-- Remove the original single-seller and active-membership-exclusivity rules.
-- Item membership is deliberately reusable while the physical copy remains
-- AVAILABLE; contributor ownership is validated below instead.
drop trigger listing_items_validate_owner on public.listing_items;
drop function public.validate_listing_item_owner();

drop trigger listing_items_exclusivity_after_item on public.listing_items;
drop trigger listing_items_exclusivity_after_listing on public.listings;
drop function public.enforce_item_listing_exclusivity();

-- Replace the original separate cardinality/state checks with one deferred
-- validator so multi-table draft assembly and lifecycle changes are atomic.
drop trigger listings_cardinality_after_listing on public.listings;
drop trigger listings_cardinality_after_item on public.listing_items;
drop function public.enforce_listing_cardinality();

drop trigger listing_inventory_state_after_listing on public.listings;
drop trigger listing_inventory_state_after_item on public.listing_items;
drop trigger listing_inventory_state_after_inventory on public.inventory_items;
drop function public.enforce_listing_inventory_state();
drop function public.assert_listing_inventory_state(uuid);

-- All deferred collaborative validators use the same advisory-lock order:
-- listing keys first, then every referenced physical-item key. Advisory locks
-- avoid the item-row/listing-row inversion that row locks would introduce.
create or replace function public.lock_collaborative_listing_set(
  target_listing_ids uuid[]
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  locked_listing_id uuid;
  locked_item_id uuid;
begin
  for locked_listing_id in
    select distinct candidate.id
    from unnest(target_listing_ids) as candidate(id)
    where candidate.id is not null
    order by candidate.id
  loop
    perform pg_advisory_xact_lock(
      hashtextextended('listing:' || locked_listing_id::text, 0)
    );
  end loop;

  for locked_item_id in
    select distinct li.item_id
    from public.listing_items li
    where li.listing_id = any(target_listing_ids)
    order by li.item_id
  loop
    perform pg_advisory_xact_lock(
      hashtextextended('item:' || locked_item_id::text, 0)
    );
  end loop;
end;
$$;

create or replace function public.validate_collaborative_listing(
  target_listing_id uuid
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  target_type public.listing_type;
  target_status public.listing_status;
  target_terms_version integer;
  target_price numeric(12, 2);
  target_deleted_at timestamptz;
  target_invalidated_at timestamptz;
  membership_count integer;
  allocated_proceeds numeric(12, 2);
  duplicate_reserved_item_id uuid;
begin
  -- Serialize final validation for each listing. Do not take row locks here:
  -- inventory writers already hold item rows, and mixing item-then-listing with
  -- listing-then-item row locks would create a deadlock cycle.
  perform public.lock_collaborative_listing_set(array[target_listing_id]);

  select
    type,
    status,
    terms_version,
    price,
    deleted_at,
    invalidated_at
  into
    target_type,
    target_status,
    target_terms_version,
    target_price,
    target_deleted_at,
    target_invalidated_at
  from public.listings
  where id = target_listing_id;

  if not found then
    return;
  end if;

  -- Terminal composition is immutable historical evidence. It intentionally
  -- keeps the seller-at-sale contributor snapshot when ownership is later
  -- transferred to a buyer, so current-owner validation no longer applies.
  if target_status not in ('DRAFT', 'ACTIVE', 'RESERVED') then
    return;
  end if;

  -- Even an incomplete draft cannot claim a physical item for somebody other
  -- than its current owner. The composite foreign key already guarantees that
  -- the contributor belongs to this listing.
  if exists (
    select 1
    from public.listing_items li
    join public.listing_contributors lc
      on lc.id = li.listing_contributor_id
     and lc.listing_id = li.listing_id
    join public.inventory_items i on i.id = li.item_id
    where li.listing_id = target_listing_id
      and lc.seller_id <> i.owner_id
  ) then
    raise exception using
      errcode = '23514',
      message = format(
        'Listing %s contains an item whose contributor is not its current owner',
        target_listing_id
      );
  end if;

  -- DRAFT listings may be incomplete and may contain pending invitations.
  if target_status = 'DRAFT' then
    return;
  end if;

  if target_deleted_at is not null or target_invalidated_at is not null then
    raise exception using
      errcode = '23514',
      message = format(
        'Actionable listing %s cannot be deleted or invalidated',
        target_listing_id
      );
  end if;

  select count(*)
  into membership_count
  from public.listing_items
  where listing_id = target_listing_id;

  if target_type = 'SINGLE' and membership_count <> 1 then
    raise exception using
      errcode = '23514',
      message = format(
        'ACTIVE/RESERVED SINGLE listing %s must contain exactly one item',
        target_listing_id
      );
  end if;

  if target_type = 'BUNDLE' and membership_count < 2 then
    raise exception using
      errcode = '23514',
      message = format(
        'ACTIVE/RESERVED BUNDLE listing %s must contain at least two items',
        target_listing_id
      );
  end if;

  -- Every invited contributor must own at least one included item and must
  -- accept this exact version of the listing terms. Checking all contributor
  -- rows also prevents an unused PENDING invitation from being published.
  if exists (
    select 1
    from public.listing_contributors lc
    where lc.listing_id = target_listing_id
      and (
        lc.status <> 'ACCEPTED'
        or lc.accepted_terms_version is distinct from target_terms_version
        or lc.proceeds_amount is null
        or not exists (
          select 1
          from public.listing_items li
          where li.listing_id = lc.listing_id
            and li.listing_contributor_id = lc.id
        )
      )
  ) then
    raise exception using
      errcode = '23514',
      message = format(
        'Actionable listing %s requires every item-owning contributor to accept current terms and proceeds',
        target_listing_id
      );
  end if;

  -- Every item must still be a live physical copy owned by the linked seller.
  -- ACTIVE offers share AVAILABLE inventory. Reserving one offer later requires
  -- a Phase 2 transaction that also retires every overlapping ACTIVE offer.
  if exists (
    select 1
    from public.listing_items li
    join public.listing_contributors lc
      on lc.id = li.listing_contributor_id
     and lc.listing_id = li.listing_id
    join public.inventory_items i on i.id = li.item_id
    where li.listing_id = target_listing_id
      and (
        lc.seller_id <> i.owner_id
        or i.deleted_at is not null
        or (
          target_status = 'ACTIVE'
          and i.status <> 'AVAILABLE'
        )
        or (
          target_status = 'RESERVED'
          and i.status <> 'RESERVED'
        )
      )
  ) then
    raise exception using
      errcode = '23514',
      message = format(
        'Actionable listing %s requires current ownership and matching AVAILABLE/RESERVED inventory state',
        target_listing_id
      );
  end if;

  if target_status = 'RESERVED' then
    select li.item_id
    into duplicate_reserved_item_id
    from public.listing_items li
    where li.listing_id = target_listing_id
      and (
        select count(distinct reserved_listing.id)
        from public.listing_items reserved_membership
        join public.listings reserved_listing
          on reserved_listing.id = reserved_membership.listing_id
        where reserved_membership.item_id = li.item_id
          and reserved_listing.status = 'RESERVED'
          and reserved_listing.deleted_at is null
          and reserved_listing.invalidated_at is null
      ) > 1
    order by li.item_id
    limit 1;

    if found then
      raise exception using
        errcode = '23514',
        message = format(
          'Inventory item %s cannot appear in more than one RESERVED listing',
          duplicate_reserved_item_id
        );
    end if;
  end if;

  select coalesce(sum(proceeds_amount), 0)
  into allocated_proceeds
  from public.listing_contributors
  where listing_id = target_listing_id;

  if allocated_proceeds <> target_price then
    raise exception using
      errcode = '23514',
      message = format(
        'Listing %s contributor proceeds must equal its asking price',
        target_listing_id
      );
  end if;
end;
$$;

create or replace function public.enforce_collaborative_listing_from_listing()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform public.validate_collaborative_listing(new.id);
  return null;
end;
$$;

create or replace function public.enforce_collaborative_listing_from_membership()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  affected_listing_ids uuid[];
  affected_listing_id uuid;
begin
  if tg_op = 'INSERT' then
    affected_listing_ids := array[new.listing_id];
  elsif tg_op = 'DELETE' then
    affected_listing_ids := array[old.listing_id];
  else
    affected_listing_ids := array[old.listing_id, new.listing_id];
  end if;

  perform public.lock_collaborative_listing_set(affected_listing_ids);

  for affected_listing_id in
    select distinct candidate.id
    from unnest(affected_listing_ids) as candidate(id)
    where candidate.id is not null
    order by candidate.id
  loop
    perform public.validate_collaborative_listing(affected_listing_id);
  end loop;

  return null;
end;
$$;

create or replace function public.enforce_collaborative_listing_from_contributor()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  affected_listing_ids uuid[];
  affected_listing_id uuid;
begin
  if tg_op = 'INSERT' then
    affected_listing_ids := array[new.listing_id];
  elsif tg_op = 'DELETE' then
    affected_listing_ids := array[old.listing_id];
  else
    affected_listing_ids := array[old.listing_id, new.listing_id];
  end if;

  perform public.lock_collaborative_listing_set(affected_listing_ids);

  for affected_listing_id in
    select distinct candidate.id
    from unnest(affected_listing_ids) as candidate(id)
    where candidate.id is not null
    order by candidate.id
  loop
    perform public.validate_collaborative_listing(affected_listing_id);
  end loop;

  return null;
end;
$$;

create or replace function public.enforce_collaborative_listing_from_inventory()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  affected_listing_ids uuid[];
  affected_listing_id uuid;
  target_item_id uuid;
begin
  target_item_id := case when tg_op = 'DELETE' then old.id else new.id end;

  select array_agg(candidate.listing_id order by candidate.listing_id)
  into affected_listing_ids
  from (
    select distinct li.listing_id
    from public.listing_items li
    where li.item_id = target_item_id
  ) candidate;

  affected_listing_ids := coalesce(affected_listing_ids, array[]::uuid[]);
  perform public.lock_collaborative_listing_set(affected_listing_ids);

  for affected_listing_id in
    select unnest(affected_listing_ids)
  loop
    perform public.validate_collaborative_listing(affected_listing_id);
  end loop;

  return null;
end;
$$;

create constraint trigger collaborative_listing_after_listing
after insert or update of
  curator_id,
  type,
  status,
  title,
  description,
  price,
  currency,
  terms_version,
  invalidated_at,
  deleted_at
on public.listings
deferrable initially deferred
for each row
execute function public.enforce_collaborative_listing_from_listing();

create constraint trigger collaborative_listing_after_membership
after insert or update or delete on public.listing_items
deferrable initially deferred
for each row
execute function public.enforce_collaborative_listing_from_membership();

create constraint trigger collaborative_listing_after_contributor
after insert or update or delete on public.listing_contributors
deferrable initially deferred
for each row
execute function public.enforce_collaborative_listing_from_contributor();

create constraint trigger collaborative_listing_after_inventory
after update of owner_id, status, deleted_at or delete on public.inventory_items
deferrable initially deferred
for each row
execute function public.enforce_collaborative_listing_from_inventory();

-- Only drafts are editable. Once published or moved to a terminal state, the
-- listing is immutable evidence; revised terms require a new listing.
create or replace function public.prepare_listing_terms_update()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  terms_changed boolean;
begin
  terms_changed :=
    new.curator_id is distinct from old.curator_id
    or new.type is distinct from old.type
    or new.title is distinct from old.title
    or new.description is distinct from old.description
    or new.price is distinct from old.price
    or new.currency is distinct from old.currency;

  if old.status <> 'DRAFT'
     and (
       terms_changed
       or new.terms_version is distinct from old.terms_version
     ) then
    raise exception using
      errcode = '23514',
      message = format(
        'Non-DRAFT listing %s terms are immutable; create a new draft instead',
        old.id
      );
  end if;

  if terms_changed then
    new.terms_version := old.terms_version + 1;
  elsif new.terms_version is distinct from old.terms_version
        and new.terms_version <> old.terms_version + 1 then
    raise exception using
      errcode = '23514',
      message = 'Listing terms_version may only advance by one';
  end if;

  return new;
end;
$$;

create trigger listings_prepare_terms_update
before update of
  curator_id,
  type,
  title,
  description,
  price,
  currency,
  terms_version
on public.listings
for each row
execute function public.prepare_listing_terms_update();

create or replace function public.prevent_terminal_listing_metadata_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status in ('CANCELLED', 'ARCHIVED', 'SOLD')
     and (
       new.invalidated_at is distinct from old.invalidated_at
       or new.invalidation_reason is distinct from old.invalidation_reason
       or new.sold_at is distinct from old.sold_at
       or new.deleted_at is distinct from old.deleted_at
     ) then
    raise exception using
      errcode = '23514',
      message = format(
        'Terminal listing %s history metadata is immutable',
        old.id
      );
  end if;

  return new;
end;
$$;

create trigger listings_prevent_terminal_metadata_mutation
before update of invalidated_at, invalidation_reason, sold_at, deleted_at
on public.listings
for each row
execute function public.prevent_terminal_listing_metadata_mutation();

create or replace function public.prevent_non_draft_membership_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  old_listing_status public.listing_status;
  new_listing_status public.listing_status;
begin
  if tg_op <> 'INSERT' then
    select status
    into old_listing_status
    from public.listings
    where id = old.listing_id;

    if old_listing_status <> 'DRAFT' then
      raise exception using
        errcode = '23514',
        message = format(
          'Non-DRAFT listing %s composition is immutable',
          old.listing_id
        );
    end if;
  end if;

  if tg_op <> 'DELETE'
     and (tg_op = 'INSERT' or new.listing_id is distinct from old.listing_id) then
    select status
    into new_listing_status
    from public.listings
    where id = new.listing_id;

    if new_listing_status <> 'DRAFT' then
      raise exception using
        errcode = '23514',
        message = format(
          'Non-DRAFT listing %s composition is immutable',
          new.listing_id
        );
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  return new;
end;
$$;

create trigger listing_items_prevent_non_draft_mutation
before insert or update or delete on public.listing_items
for each row
execute function public.prevent_non_draft_membership_mutation();

create or replace function public.prevent_non_draft_contributor_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  old_listing_status public.listing_status;
  new_listing_status public.listing_status;
begin
  if tg_op <> 'INSERT' then
    select status
    into old_listing_status
    from public.listings
    where id = old.listing_id;

    if old_listing_status <> 'DRAFT' then
      -- A current seller may withdraw an actionable contribution only as part
      -- of the same transaction that retires the listing. Preserve the exact
      -- accepted terms/proceeds snapshot; the deferred validator requires the
      -- listing to be terminal by commit.
      if old_listing_status in ('ACTIVE', 'RESERVED')
         and tg_op = 'UPDATE'
         and old.status = 'ACCEPTED'
         and new.status = 'WITHDRAWN'
         and new.id is not distinct from old.id
         and new.listing_id is not distinct from old.listing_id
         and new.seller_id is not distinct from old.seller_id
         and new.accepted_terms_version is not distinct from old.accepted_terms_version
         and new.proceeds_amount is not distinct from old.proceeds_amount
         and new.responded_at is not distinct from old.responded_at
         and new.accepted_at is not distinct from old.accepted_at
         and new.created_at is not distinct from old.created_at then
        return new;
      end if;

      raise exception using
        errcode = '23514',
        message = format(
          'Non-DRAFT listing %s contributor terms are immutable',
          old.listing_id
        );
    end if;
  end if;

  if tg_op <> 'DELETE'
     and (tg_op = 'INSERT' or new.listing_id is distinct from old.listing_id) then
    select status
    into new_listing_status
    from public.listings
    where id = new.listing_id;

    if new_listing_status <> 'DRAFT' then
      raise exception using
        errcode = '23514',
        message = format(
          'Non-DRAFT listing %s contributor terms are immutable',
          new.listing_id
        );
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  return new;
end;
$$;

create trigger listing_contributors_prevent_non_draft_mutation
before insert or update or delete on public.listing_contributors
for each row
execute function public.prevent_non_draft_contributor_mutation();

-- Draft composition and proceeds are listing terms. Advance the version after
-- each such change so previous acceptances cannot be reused accidentally.
create or replace function public.bump_listing_terms_for_membership()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op <> 'INSERT' then
    update public.listings
    set terms_version = terms_version + 1
    where id = old.listing_id;
  end if;

  if tg_op <> 'DELETE'
     and (tg_op = 'INSERT' or new.listing_id is distinct from old.listing_id) then
    update public.listings
    set terms_version = terms_version + 1
    where id = new.listing_id;
  end if;

  return null;
end;
$$;

create trigger listing_items_bump_terms_version
after insert or update or delete on public.listing_items
for each row
execute function public.bump_listing_terms_for_membership();

create or replace function public.bump_listing_terms_for_contributor()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    update public.listings
    set terms_version = terms_version + 1
    where id = new.listing_id;
  elsif tg_op = 'DELETE' then
    update public.listings
    set terms_version = terms_version + 1
    where id = old.listing_id;
  elsif new.listing_id is distinct from old.listing_id
        or new.seller_id is distinct from old.seller_id
        or new.proceeds_amount is distinct from old.proceeds_amount then
    update public.listings
    set terms_version = terms_version + 1
    where id = old.listing_id;

    if new.listing_id is distinct from old.listing_id then
      update public.listings
      set terms_version = terms_version + 1
      where id = new.listing_id;
    end if;
  end if;

  return null;
end;
$$;

create trigger listing_contributors_bump_terms_version
after insert or update of listing_id, seller_id, proceeds_amount or delete
on public.listing_contributors
for each row
execute function public.bump_listing_terms_for_contributor();

comment on column public.listings.curator_id is
  'Profile organizing the offer; not necessarily the owner of every included physical item.';
comment on column public.listings.terms_version is
  'Monotonic version of price, composition, proceeds, and other contributor-approved terms.';
comment on table public.listing_contributors is
  'Per-seller consent and proposed gross proceeds allocation for a collaborative listing.';
comment on column public.listing_items.listing_contributor_id is
  'Contributor that must remain the current owner of this physical inventory item.';

-- Phase 1 has no order-backed purchase record. Reject fabricated SOLD states
-- until the Phase 2 checkout transaction replaces this guard.
create or replace function public.prevent_phase1_unbacked_sale()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = 'SOLD'
     and (tg_op = 'INSERT' or old.status is distinct from 'SOLD') then
    raise exception using
      errcode = '23514',
      message = 'SOLD requires the Phase 2 order-backed purchase transaction';
  end if;

  return new;
end;
$$;

create trigger listings_prevent_phase1_unbacked_sale
before insert or update of status on public.listings
for each row
execute function public.prevent_phase1_unbacked_sale();

create or replace function public.prevent_phase1_unbacked_inventory_sale()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = 'SOLD'
     and (tg_op = 'INSERT' or old.status is distinct from 'SOLD') then
    raise exception using
      errcode = '23514',
      message = 'SOLD requires the Phase 2 order-backed purchase transaction';
  end if;

  return new;
end;
$$;

create trigger inventory_items_prevent_phase1_unbacked_sale
before insert or update of status on public.inventory_items
for each row
execute function public.prevent_phase1_unbacked_inventory_sale();

create or replace function public.validate_listing_lifecycle_transition()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'DRAFT' then
      raise exception using
        errcode = '23514',
        message = 'A new listing must start in DRAFT';
    end if;

    return new;
  end if;

  if new.status = old.status then
    return new;
  end if;

  if (
    old.status = 'DRAFT'
    and new.status in ('ACTIVE', 'CANCELLED', 'ARCHIVED')
  ) or (
    old.status = 'ACTIVE'
    and new.status in ('RESERVED', 'CANCELLED', 'ARCHIVED')
  ) or (
    old.status = 'RESERVED'
    and new.status in ('ACTIVE', 'CANCELLED', 'ARCHIVED')
  ) then
    return new;
  end if;

  raise exception using
    errcode = '23514',
    message = format(
      'Invalid listing lifecycle transition from %s to %s',
      old.status,
      new.status
    );
end;
$$;

-- This trigger sorts after listings_prevent_phase1_unbacked_sale, preserving
-- the explicit Phase 2 boundary message for attempted SOLD transitions.
create trigger listings_validate_lifecycle_transition
before insert or update of status on public.listings
for each row
execute function public.validate_listing_lifecycle_transition();

-- Supabase participant helpers are SECURITY DEFINER to avoid recursive RLS
-- evaluation while still deriving every decision from auth.uid().
create or replace function public.is_listing_curator(target_listing_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.listings l
    where l.id = target_listing_id
      and l.curator_id = public.current_profile_id()
  )
$$;

create or replace function public.is_listing_contributor(target_listing_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.listing_contributors lc
    where lc.listing_id = target_listing_id
      and lc.seller_id = public.current_profile_id()
  )
$$;

create or replace function public.listing_is_draft(target_listing_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.listings l
    where l.id = target_listing_id
      and l.status = 'DRAFT'
      and l.deleted_at is null
  )
$$;

-- Curators propose inventory only through this atomic path. It derives the
-- seller from the physical item, so a curator cannot forge its contributor.
create or replace function public.propose_listing_item(
  target_listing_id uuid,
  target_item_id uuid,
  target_proceeds_amount numeric default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_profile_id uuid;
  listing_curator_id uuid;
  target_listing_type public.listing_type;
  target_listing_status public.listing_status;
  target_listing_deleted_at timestamptz;
  item_owner_id uuid;
  item_status public.inventory_status;
  item_deleted_at timestamptz;
  target_contributor_id uuid;
  target_membership_id uuid;
  current_terms_version integer;
begin
  caller_profile_id := public.current_profile_id();

  perform public.lock_collaborative_listing_set(array[target_listing_id]);
  perform pg_advisory_xact_lock(
    hashtextextended('item:' || target_item_id::text, 0)
  );

  select curator_id, type, status, deleted_at
  into
    listing_curator_id,
    target_listing_type,
    target_listing_status,
    target_listing_deleted_at
  from public.listings
  where id = target_listing_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Listing does not exist';
  end if;

  if not public.is_privileged()
     and listing_curator_id is distinct from caller_profile_id then
    raise exception using
      errcode = '42501',
      message = 'Only the listing curator may propose inventory';
  end if;

  if target_listing_status <> 'DRAFT' or target_listing_deleted_at is not null then
    raise exception using
      errcode = '23514',
      message = 'Inventory may only be proposed to a live DRAFT listing';
  end if;

  if target_proceeds_amount is not null and target_proceeds_amount < 0 then
    raise exception using
      errcode = '23514',
      message = 'Contributor proceeds cannot be negative';
  end if;

  if target_listing_type = 'SINGLE'
     and exists (
       select 1
       from public.listing_items li
       where li.listing_id = target_listing_id
     ) then
    raise exception using
      errcode = '23514',
      message = 'A SINGLE draft may contain at most one physical item';
  end if;

  if exists (
    select 1
    from public.listing_items li
    where li.listing_id = target_listing_id
      and li.item_id = target_item_id
  ) then
    raise exception using
      errcode = '23505',
      message = 'This physical item is already in the listing';
  end if;

  select owner_id, status, deleted_at
  into item_owner_id, item_status, item_deleted_at
  from public.inventory_items
  where id = target_item_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Inventory item does not exist';
  end if;

  if item_status <> 'AVAILABLE' or item_deleted_at is not null then
    raise exception using
      errcode = '23514',
      message = 'Only a live AVAILABLE physical item may be proposed';
  end if;

  insert into public.listing_contributors (
    listing_id,
    seller_id,
    status,
    accepted_terms_version,
    proceeds_amount,
    responded_at,
    accepted_at
  ) values (
    target_listing_id,
    item_owner_id,
    'PENDING',
    null,
    target_proceeds_amount,
    null,
    null
  )
  on conflict (listing_id, seller_id) do update
  set
    status = 'PENDING',
    accepted_terms_version = null,
    proceeds_amount = excluded.proceeds_amount,
    responded_at = null,
    accepted_at = null
  returning id into target_contributor_id;

  insert into public.listing_items (
    listing_id,
    item_id,
    listing_contributor_id
  ) values (
    target_listing_id,
    target_item_id,
    target_contributor_id
  )
  returning id into target_membership_id;

  -- The curator may consent for their own physical item. Every other owner must
  -- respond for themselves after all version-bumping proposal triggers run.
  if item_owner_id = listing_curator_id then
    select terms_version
    into current_terms_version
    from public.listings
    where id = target_listing_id;

    update public.listing_contributors
    set
      status = 'ACCEPTED',
      accepted_terms_version = current_terms_version,
      responded_at = statement_timestamp(),
      accepted_at = statement_timestamp()
    where id = target_contributor_id;
  end if;

  return target_membership_id;
end;
$$;

create or replace function public.remove_listing_item(
  target_listing_id uuid,
  target_listing_item_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_profile_id uuid;
  listing_curator_id uuid;
  target_listing_status public.listing_status;
  target_listing_deleted_at timestamptz;
  target_contributor_id uuid;
  current_terms_version integer;
begin
  caller_profile_id := public.current_profile_id();

  perform public.lock_collaborative_listing_set(array[target_listing_id]);

  select curator_id, status, deleted_at
  into listing_curator_id, target_listing_status, target_listing_deleted_at
  from public.listings
  where id = target_listing_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Listing does not exist';
  end if;

  if not public.is_privileged()
     and listing_curator_id is distinct from caller_profile_id then
    raise exception using
      errcode = '42501',
      message = 'Only the listing curator may remove proposed inventory';
  end if;

  if target_listing_status <> 'DRAFT' or target_listing_deleted_at is not null then
    raise exception using
      errcode = '23514',
      message = 'Inventory may only be removed from a live DRAFT listing';
  end if;

  select listing_contributor_id
  into target_contributor_id
  from public.listing_items
  where id = target_listing_item_id
    and listing_id = target_listing_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Listing membership does not exist';
  end if;

  delete from public.listing_items
  where id = target_listing_item_id;

  if not exists (
    select 1
    from public.listing_items li
    where li.listing_id = target_listing_id
      and li.listing_contributor_id = target_contributor_id
  ) then
    delete from public.listing_contributors
    where id = target_contributor_id;
  end if;

  -- Refresh curator consent after the membership/contributor triggers advance
  -- the terms version. Other sellers must explicitly reaccept the new version.
  select terms_version
  into current_terms_version
  from public.listings
  where id = target_listing_id;

  update public.listing_contributors
  set
    status = 'ACCEPTED',
    accepted_terms_version = current_terms_version,
    responded_at = statement_timestamp(),
    accepted_at = statement_timestamp()
  where listing_id = target_listing_id
    and seller_id = listing_curator_id;
end;
$$;

create or replace function public.update_draft_listing(
  target_listing_id uuid,
  target_type public.listing_type,
  target_title text,
  target_description text,
  target_price numeric,
  target_currency char(3)
)
returns public.listings
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_profile_id uuid;
  target_listing public.listings;
begin
  caller_profile_id := public.current_profile_id();

  perform public.lock_collaborative_listing_set(array[target_listing_id]);

  select *
  into target_listing
  from public.listings
  where id = target_listing_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Listing does not exist';
  end if;

  if not public.is_privileged()
     and target_listing.curator_id is distinct from caller_profile_id then
    raise exception using
      errcode = '42501',
      message = 'Only the listing curator may revise its draft terms';
  end if;

  if target_listing.status <> 'DRAFT' or target_listing.deleted_at is not null then
    raise exception using
      errcode = '23514',
      message = 'Only a live DRAFT listing may be revised';
  end if;

  if row(
    target_type,
    target_title,
    target_description,
    target_price,
    target_currency
  ) is not distinct from row(
    target_listing.type,
    target_listing.title,
    target_listing.description,
    target_listing.price,
    target_listing.currency
  ) then
    return target_listing;
  end if;

  update public.listings
  set
    type = target_type,
    title = target_title,
    description = target_description,
    price = target_price,
    currency = target_currency,
    invalidated_at = statement_timestamp(),
    invalidation_reason = 'TERMS_CHANGED_REAPPROVAL_REQUIRED'
  where id = target_listing_id
  returning * into target_listing;

  return target_listing;
end;
$$;

create or replace function public.update_draft_contributor_proceeds(
  target_listing_id uuid,
  target_contribution_id uuid,
  target_proceeds_amount numeric
)
returns public.listing_contributors
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_profile_id uuid;
  target_listing public.listings;
  target_contribution public.listing_contributors;
begin
  if target_proceeds_amount is null or target_proceeds_amount < 0 then
    raise exception using
      errcode = '23514',
      message = 'Contributor proceeds must be a nonnegative amount';
  end if;

  caller_profile_id := public.current_profile_id();

  perform public.lock_collaborative_listing_set(array[target_listing_id]);

  select *
  into target_listing
  from public.listings
  where id = target_listing_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Listing does not exist';
  end if;

  if not public.is_privileged()
     and target_listing.curator_id is distinct from caller_profile_id then
    raise exception using
      errcode = '42501',
      message = 'Only the listing curator may revise contributor proceeds';
  end if;

  if target_listing.status <> 'DRAFT' or target_listing.deleted_at is not null then
    raise exception using
      errcode = '23514',
      message = 'Contributor proceeds may only be revised on a live DRAFT listing';
  end if;

  select *
  into target_contribution
  from public.listing_contributors
  where id = target_contribution_id
    and listing_id = target_listing_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Listing contribution does not exist';
  end if;

  update public.listing_contributors
  set
    proceeds_amount = target_proceeds_amount,
    status = 'PENDING',
    accepted_terms_version = null,
    responded_at = null,
    accepted_at = null
  where id = target_contribution_id
  returning * into target_contribution;

  return target_contribution;
end;
$$;

create or replace function public.respond_to_listing_contribution(
  target_contribution_id uuid,
  target_status public.listing_contributor_status
)
returns public.listing_contributors
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_profile_id uuid;
  contribution_listing_id uuid;
  target_contribution public.listing_contributors;
  target_listing public.listings;
  target_terms_version integer;
  response_time timestamptz := statement_timestamp();
begin
  if target_status not in ('ACCEPTED', 'REJECTED', 'WITHDRAWN') then
    raise exception using
      errcode = '23514',
      message = 'A contribution response must be ACCEPTED, REJECTED, or WITHDRAWN';
  end if;

  caller_profile_id := public.current_profile_id();

  -- Discover the parent without locking, then take locks in the same
  -- listing-before-contributor order used by curator proposal RPCs.
  select listing_id
  into contribution_listing_id
  from public.listing_contributors
  where id = target_contribution_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Listing contribution does not exist';
  end if;

  perform public.lock_collaborative_listing_set(array[contribution_listing_id]);

  select *
  into target_listing
  from public.listings
  where id = contribution_listing_id
  for update;

  select *
  into target_contribution
  from public.listing_contributors
  where id = target_contribution_id
    and listing_id = contribution_listing_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Listing contribution no longer exists';
  end if;

  if not public.is_privileged()
     and target_contribution.seller_id is distinct from caller_profile_id then
    raise exception using
      errcode = '42501',
      message = 'Only the current contributing seller may respond';
  end if;

  if target_status = 'ACCEPTED' then
    if target_listing.status <> 'DRAFT' or target_listing.deleted_at is not null then
      raise exception using
        errcode = '23514',
        message = 'Only a live DRAFT contribution may be accepted';
    end if;

    if target_contribution.proceeds_amount is null then
      raise exception using
        errcode = '23514',
        message = 'A seller must receive a proposed proceeds amount before accepting';
    end if;

    if not exists (
      select 1
      from public.listing_items li
      where li.listing_contributor_id = target_contribution.id
    ) or exists (
      select 1
      from public.listing_items li
      join public.inventory_items i on i.id = li.item_id
      where li.listing_contributor_id = target_contribution.id
        and (
          i.owner_id <> target_contribution.seller_id
          or i.status <> 'AVAILABLE'
          or i.deleted_at is not null
        )
    ) then
      raise exception using
        errcode = '23514',
        message = 'Every contributed physical item must still be live, AVAILABLE, and owned by the responding seller';
    end if;

    target_terms_version := target_listing.terms_version;

    update public.listing_contributors
    set
      status = 'ACCEPTED',
      accepted_terms_version = target_terms_version,
      responded_at = response_time,
      accepted_at = response_time
    where id = target_contribution_id
    returning * into target_contribution;
  elsif target_listing.status in ('ACTIVE', 'RESERVED') then
    if target_status <> 'WITHDRAWN' then
      raise exception using
        errcode = '23514',
        message = 'An actionable contribution may only be withdrawn';
    end if;

    -- Preserve the accepted version, proceeds, and acceptance timestamps. The
    -- narrow trigger exception permits only this status change, and deferred
    -- validation requires the listing to be retired in the same transaction.
    update public.listing_contributors
    set status = 'WITHDRAWN'
    where id = target_contribution_id
    returning * into target_contribution;

    update public.listings
    set
      status = 'ARCHIVED',
      invalidated_at = response_time,
      invalidation_reason = 'CONTRIBUTOR_WITHDREW'
    where id = target_listing.id;
  else
    if target_listing.status <> 'DRAFT' then
      raise exception using
        errcode = '23514',
        message = 'Only DRAFT or actionable contributions may receive a response';
    end if;

    update public.listing_contributors
    set
      status = target_status,
      accepted_terms_version = null,
      responded_at = response_time,
      accepted_at = null
    where id = target_contribution_id
    returning * into target_contribution;
  end if;

  return target_contribution;
end;
$$;

create or replace function public.publish_listing(target_listing_id uuid)
returns public.listings
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_profile_id uuid;
  target_listing public.listings;
begin
  caller_profile_id := public.current_profile_id();

  perform public.lock_collaborative_listing_set(array[target_listing_id]);

  select *
  into target_listing
  from public.listings
  where id = target_listing_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Listing does not exist';
  end if;

  if not public.is_privileged()
     and target_listing.curator_id is distinct from caller_profile_id then
    raise exception using
      errcode = '42501',
      message = 'Only the listing curator may publish it';
  end if;

  if target_listing.status <> 'DRAFT' or target_listing.deleted_at is not null then
    raise exception using
      errcode = '23514',
      message = 'Only a live DRAFT listing may be published';
  end if;

  update public.listings
  set
    status = 'ACTIVE',
    invalidated_at = null,
    invalidation_reason = null
  where id = target_listing_id
  returning * into target_listing;

  -- Give RPC callers an immediate actionable error rather than waiting for the
  -- deferred constraint trigger at transaction commit.
  perform public.validate_collaborative_listing(target_listing_id);

  return target_listing;
end;
$$;

create or replace function public.retire_listing(
  target_listing_id uuid,
  target_status public.listing_status default 'ARCHIVED'
)
returns public.listings
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_profile_id uuid;
  target_listing public.listings;
  response_time timestamptz := statement_timestamp();
begin
  if target_status not in ('CANCELLED', 'ARCHIVED') then
    raise exception using
      errcode = '23514',
      message = 'A curator may retire a listing only as CANCELLED or ARCHIVED';
  end if;

  caller_profile_id := public.current_profile_id();

  perform public.lock_collaborative_listing_set(array[target_listing_id]);

  select *
  into target_listing
  from public.listings
  where id = target_listing_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Listing does not exist';
  end if;

  if not public.is_privileged()
     and target_listing.curator_id is distinct from caller_profile_id then
    raise exception using
      errcode = '42501',
      message = 'Only the listing curator may retire it';
  end if;

  if target_listing.status not in ('DRAFT', 'ACTIVE', 'RESERVED') then
    raise exception using
      errcode = '23514',
      message = 'A terminal listing cannot be retired or rewritten again';
  end if;

  update public.listings
  set
    status = target_status,
    invalidated_at = response_time,
    invalidation_reason = case
      when target_status = 'CANCELLED' then 'CANCELLED_BY_CURATOR'
      else 'ARCHIVED_BY_CURATOR'
    end
  where id = target_listing_id
  returning * into target_listing;

  return target_listing;
end;
$$;

alter table public.listing_contributors enable row level security;

-- Public profile reads go through a safe projection. A profile owner may still
-- read their own base row, including auth_user_id, but no other user can.
drop policy profiles_public_read on public.profiles;

create policy profiles_owner_read
on public.profiles
for select
to authenticated
using (
  auth_user_id = (select auth.uid())
  or public.is_privileged()
);

create or replace view public.public_profiles
with (security_barrier = true)
as
select
  p.id,
  p.username,
  p.display_name,
  p.bio,
  p.avatar_path,
  p.created_at,
  p.updated_at
from public.profiles p;

revoke all on table public.public_profiles from public;
grant select on table public.public_profiles to anon, authenticated;

-- Curators own listing workflow; contributors can inspect any listing in which
-- they participate, while only live ACTIVE offers are public.
drop policy listings_public_or_owner_read on public.listings;
drop policy listings_owner_insert on public.listings;
drop policy listings_owner_update on public.listings;

create policy listings_public_or_participant_read
on public.listings
for select
to anon, authenticated
using (
  (status = 'ACTIVE' and deleted_at is null)
  or public.is_listing_curator(id)
  or public.is_listing_contributor(id)
  or public.is_privileged()
);

create policy listings_curator_insert
on public.listings
for insert
to authenticated
with check (
  (
    curator_id = public.current_profile_id()
    and status = 'DRAFT'
    and terms_version = 1
    and sold_at is null
    and deleted_at is null
    and invalidated_at is null
    and invalidation_reason is null
  )
  or public.is_privileged()
);

create policy listings_curator_update_draft_terms
on public.listings
for update
to authenticated
using (
  public.is_listing_curator(id)
  or public.is_privileged()
)
with check (
  curator_id = public.current_profile_id()
  or public.is_privileged()
);

drop policy listing_items_public_or_owner_read on public.listing_items;
drop policy listing_items_owner_insert on public.listing_items;
drop policy listing_items_owner_delete_draft on public.listing_items;

create policy listing_items_public_or_participant_read
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
        or public.is_listing_curator(l.id)
        or public.is_listing_contributor(l.id)
        or public.is_privileged()
      )
  )
);

-- Consent and proposed proceeds remain participant-only. Raw inserts/deletes
-- are intentionally unavailable; curators use propose/remove RPCs.
create policy listing_contributors_participant_read
on public.listing_contributors
for select
to authenticated
using (
  public.is_listing_curator(listing_id)
  or public.is_listing_contributor(listing_id)
  or public.is_privileged()
);

create policy listing_contributors_seller_respond
on public.listing_contributors
for update
to authenticated
using (
  seller_id = public.current_profile_id()
  and public.listing_is_draft(listing_id)
)
with check (
  seller_id = public.current_profile_id()
  and public.listing_is_draft(listing_id)
  and (
    (
      status = 'ACCEPTED'
      and accepted_terms_version = (
        select l.terms_version
        from public.listings l
        where l.id = listing_id
      )
      and responded_at is not null
      and accepted_at is not null
    )
    or
    (
      status = 'REJECTED'
      and accepted_terms_version is null
      and responded_at is not null
      and accepted_at is null
    )
    or
    (
      status = 'WITHDRAWN'
      and responded_at is not null
      and (
        (
          accepted_terms_version is null
          and accepted_at is null
        )
        or
        (
          accepted_terms_version is not null
          and accepted_at is not null
        )
      )
    )
  )
);

-- Listing media is authored and stored only by the curator, not by every item
-- contributor. Draft participants may read it to evaluate the proposal.
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
            and l.curator_id = public.current_profile_id()
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
            and (
              (l.status = 'ACTIVE' and l.deleted_at is null)
              or public.is_listing_curator(l.id)
              or public.is_listing_contributor(l.id)
            )
        )
        else false
      end
    )
$$;

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
          and l.curator_id = public.current_profile_id()
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
            or public.is_listing_curator(l.id)
            or public.is_listing_contributor(l.id)
          )
      )
      else false
    end
$$;

-- Replace the original broad column grants with safe projections, constrained
-- draft-term edits, contributor response fields, and RPC-only composition.
revoke all on table public.profiles from anon, authenticated;
grant select on table public.profiles to authenticated;
grant insert (auth_user_id, username, display_name, bio, avatar_path)
  on table public.profiles to authenticated;
grant update (username, display_name, bio, avatar_path)
  on table public.profiles to authenticated;

-- Table-level REVOKE does not remove column ACLs inherited from the baseline
-- migration, so revoke every legacy write list explicitly before narrowing it.
revoke insert (
  curator_id, type, status, title, description, price, currency
) on table public.listings from authenticated;
revoke update (
  type, status, title, description, price, currency, sold_at, deleted_at
) on table public.listings from authenticated;
revoke all on table public.listings from anon, authenticated;
grant select on table public.listings to anon, authenticated;
grant insert (
  curator_id, type, title, description, price, currency
) on table public.listings to authenticated;

revoke insert (listing_id, item_id, quantity)
  on table public.listing_items from authenticated;
revoke all on table public.listing_items from anon, authenticated;
grant select on table public.listing_items to anon, authenticated;

revoke all on table public.listing_contributors from anon, authenticated;
grant select on table public.listing_contributors to authenticated;

grant usage on type public.listing_contributor_status to authenticated;

-- Internal integrity helpers are not anonymous RPCs. Authenticated and
-- service-role writes need EXECUTE because invoker-mode trigger functions call
-- them while validating the transaction.
revoke all on function public.lock_collaborative_listing_set(uuid[])
  from public, anon;
revoke all on function public.validate_collaborative_listing(uuid)
  from public, anon;
grant execute on function public.lock_collaborative_listing_set(uuid[])
  to authenticated, service_role;
grant execute on function public.validate_collaborative_listing(uuid)
  to authenticated, service_role;

revoke all on function public.is_listing_curator(uuid) from public;
revoke all on function public.is_listing_contributor(uuid) from public;
revoke all on function public.listing_is_draft(uuid) from public;
revoke all on function public.propose_listing_item(uuid, uuid, numeric) from public;
revoke all on function public.remove_listing_item(uuid, uuid) from public;
revoke all on function public.update_draft_listing(
  uuid, public.listing_type, text, text, numeric, char
) from public;
revoke all on function public.update_draft_contributor_proceeds(
  uuid, uuid, numeric
) from public;
revoke all on function public.respond_to_listing_contribution(
  uuid, public.listing_contributor_status
) from public;
revoke all on function public.publish_listing(uuid) from public;
revoke all on function public.retire_listing(uuid, public.listing_status) from public;

grant execute on function public.is_listing_curator(uuid) to anon, authenticated;
grant execute on function public.is_listing_contributor(uuid) to anon, authenticated;
grant execute on function public.listing_is_draft(uuid) to authenticated;
grant execute on function public.propose_listing_item(uuid, uuid, numeric)
  to authenticated;
grant execute on function public.remove_listing_item(uuid, uuid)
  to authenticated;
grant execute on function public.update_draft_listing(
  uuid, public.listing_type, text, text, numeric, char
) to authenticated;
grant execute on function public.update_draft_contributor_proceeds(
  uuid, uuid, numeric
) to authenticated;
grant execute on function public.respond_to_listing_contribution(
  uuid, public.listing_contributor_status
) to authenticated;
grant execute on function public.publish_listing(uuid) to authenticated;
grant execute on function public.retire_listing(uuid, public.listing_status)
  to authenticated;

commit;
