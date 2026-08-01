# MangaMarketplace Schema Parity Contract

The Phase 1 Figma ERD and specification define one domain model with two
deployment adapters. Shared tables, columns, types, checks, foreign-key actions,
indexes, and integrity triggers must remain equivalent between the local and
Supabase migrations.

The collaborative collector-listing clarification supersedes the original
same-seller and active-membership-exclusivity assumptions. It is implemented as
matching forward migrations so previously applied baseline migrations remain
immutable.

## Canonical files

- Local PostgreSQL: `database/migrations/001_phase1_marketplace.sql`
- Local collaborative-listing forward migration:
  `database/migrations/002_collaborative_collector_listings.sql`
- Local smoke test: `database/tests/phase1_schema.sql`
- Supabase schema: `supabase/migrations/20260731120000_schema.sql`
- Supabase security/Storage: `supabase/migrations/20260731121000_integrity_rls_storage.sql`
- Supabase collaborative-listing and RLS forward migration:
  `supabase/migrations/20260731122000_collaborative_collector_listings.sql`
- Supabase pgTAP tests: `supabase/tests/rls.sql`

## Intentional deployment differences

| Concern | Local PostgreSQL | Supabase |
| --- | --- | --- |
| Authentication user | `public.auth_users` | Managed `auth.users` |
| Profile foreign key | `profiles.auth_user_id -> auth_users.id` | `profiles.auth_user_id -> auth.users.id` |
| Password hashes | `auth_users.password_hash` | Managed by Supabase Auth |
| Refresh tokens | Added later only if local auth needs them | Managed by Supabase Auth |
| Authorization enforcement | NestJS guards and transactions | PostgreSQL RLS plus application transactions |
| Object storage | Configured by the local application | Private Supabase Storage buckets and policies |
| Public profile projection | Application DTO/serializer | `public_profiles` safe view |
| Collaborative write workflow | NestJS transaction services | Authenticated `SECURITY DEFINER` RPCs |

No other difference in the eight shared physical tables, enums, constraints,
indexes, or integrity triggers is intentional.

## Shared domain tables

- `profiles`
- `user_roles`
- `catalog_products`
- `inventory_items`
- `listings`
- `listing_contributors`
- `listing_items`
- `media_assets`

Every resource has its own UUID. A catalog product describes one release and
may be referenced by many inventory rows. Each inventory item represents
exactly one independently sellable physical copy with one current owner. A
listing is one offer assembled by a curator and contains those copies through
`listing_items`; a collector listing may combine several owners' copies.

## Approved schema extensions beyond the minimum ERD

- Catalog creation provenance and soft deletion.
- Decimal volume numbers for special releases such as volume `0.5`.
- Listing title, description, ISO-shaped currency, sale timestamp, and soft deletion.
- Listing curator, versioned terms, and invalidation metadata.
- One versioned contributor-consent record per seller in a listing, including an
  optional proposed proceeds amount for later settlement design.
- Enumerated item conditions and media types.
- Media soft deletion and strict bucket/path-to-resource matching.

These extensions do not collapse or replace any entity required by the ERD.

## Collaborative schema expectations

The two deployment tracks must expose the same collaborative-listing shape:

| Object | Required contract |
| --- | --- |
| `listing_contributor_status` | Enum values `PENDING`, `ACCEPTED`, `REJECTED`, and `WITHDRAWN` |
| `listings` | `curator_id` replaces the former sole-seller relationship; `terms_version` is positive; `invalidated_at` and `invalidation_reason` preserve invalidation history |
| `listing_contributors` | UUID `id`; `listing_id`; contributing `seller_id`; consent `status`; `accepted_terms_version`; optional nonnegative `proceeds_amount`; response/acceptance and audit timestamps; unique `(listing_id, seller_id)` |
| `listing_items` | One membership per `(listing_id, item_id)` plus a required `listing_contributor_id`; its composite foreign key must keep the contributor and item membership in the same listing; the legacy `quantity` column remains constrained to `1` |
| `inventory_items` | One row means one physical copy and has no aggregate quantity column. |

There must be no global or partial uniqueness rule that prevents an available
`item_id` from appearing in several active listings. The same catalog product
may also have any number of independently owned inventory items.

The shared trigger contract must:

- defer actionable-listing integrity checks until transaction commit so a
  multi-row draft-to-active transition can be completed atomically;
- verify that each mutable/actionable membership's contributor is the physical
  item's current owner while preserving terminal seller snapshots;
- require current accepted terms and matching item availability for actionable
  listings;
- require every contributor to have an included item and an allocation, with
  `proceeds_amount` values summing to the listing price;
- enforce one-item `SINGLE` and two-or-more-item `BUNDLE` cardinality only when
  the listing is actionable;
- allow active overlap but permit at most one reserved listing per physical
  item;
- prevent terms or membership mutation after a listing leaves `DRAFT`; and
- reject direct listing or inventory `SOLD` transitions until Phase 2 replaces
  those guards with an order-backed atomic purchase transaction.

`validate_collaborative_listing` and the deferred
`collaborative_listing_after_*` constraint triggers provide the shared commit
gate. Draft terms, membership, and proceeds changes advance `terms_version`;
old acceptances do not authorize the revised offer.

The former same-seller validation and one-active-listing-per-item exclusivity
triggers are not part of the collaborative contract and must be removed by the
forward migration.

## Protected information

- Authentication email is never duplicated in `profiles`.
- Local password hashes remain only in `auth_users`.
- Supabase password hashes and refresh tokens remain only in Supabase Auth.
- `inventory_items.acquisition_price` and `condition_notes` are seller-private.
- Supabase public reads use `marketplace_inventory_items`, which omits private fields.

`listing_contributors.proceeds_amount` and consent metadata are participant
data, not anonymous marketplace data. Public listing projections may expose the
offer and its accepted item composition without exposing private seller costs,
notes, authentication identifiers, or proposed allocation details.

## Supabase RLS expectations

Supabase RLS must preserve the same domain model while enforcing participant
roles:

- Public clients may read active listings and their item composition.
- A curator may create and manage only their own draft listing and composition.
- A contributing seller may discover listings containing their contributions
  and respond only for their own `listing_contributors` row.
- Raw listing lifecycle, listing-item, and contributor-response writes are
  revoked; authenticated RPCs enforce authorization and advisory-lock order.
- A curator cannot accept current terms on behalf of another seller, and a
  seller cannot approve or withdraw another seller's contribution.
- Participant-only reads protect contributor consent and proposed proceeds.
- Inventory private fields remain owner-only, listing media remains controlled
  by the curator, and privileged-role policies remain unchanged.

RLS filters rows, not columns. Safe public views/grants must therefore continue
to be used wherever a base table also contains private columns.

## Storage path contract

All Supabase buckets are private. Reads are policy-controlled or use signed URLs.

| Media type | Bucket | Object path |
| --- | --- | --- |
| Avatar | `avatars` | `<profileId>/<filename>` |
| Product | `product-media` | `<productId>/<filename>` |
| Item | `item-media` | `<itemId>/<filename>` |
| Listing | `listing-media` | `<listingId>/<filename>` |

`media_assets` checks that the bucket, first path segment, media type, and target
foreign key agree.

## Transaction invariants

The database validates these invariants at transaction commit:

1. An actionable `SINGLE` contains exactly one physical item.
2. An actionable `BUNDLE` contains at least two physical items and may include
   several sellers.
3. Every draft/actionable membership points to the contributor who currently
   owns that item; terminal history retains its seller snapshot.
4. Every actionable contributor has accepted the listing's current
   `terms_version`.
5. Every actionable contributor owns at least one included item and has a
   proposed proceeds amount; those amounts sum to the listing price.
6. Active listings contain available items and reserved listings contain
   reserved items.
7. One available item may appear in several active listings, but no item may
   belong to more than one reserved listing.
8. Terms and composition are immutable after a listing leaves `DRAFT`.
9. Phase 1 cannot create a `SOLD` listing or inventory item without the future
   purchase workflow.

Regular users must never receive a database path that can grant `DEVELOPER` or
`ADMIN`; Supabase RLS independently enforces that rule in cloud deployments.

## Phase 2 winning-purchase boundary

Phase 1 does not provide checkout, order, payment, sale, or payout APIs. The
optional contributor proceeds value records proposed terms only; it is not a
ledger or proof of payment.

A future winning-purchase command must lock the selected listing and every
constituent item, revalidate consent, ownership, and availability, and claim the
whole listing atomically. Only that selected listing becomes sold. All other
active listings containing any claimed item must be archived or invalidated in
the same transaction while preserving their listing-item and contributor
history. A competing collector set must never remain active with silently
reduced composition or its former price.

## Deployment and verification

### Local

1. Apply `001_phase1_marketplace.sql`, then
   `002_collaborative_collector_listings.sql`, to a fresh PostgreSQL database.
2. Run `database/tests/phase1_schema.sql` with `ON_ERROR_STOP=1`.
3. Run Prisma validation, generation, seeds, build, and Jest after Prisma is added.

### Supabase

1. Place the `supabase` directory at the Supabase CLI project root.
2. Run `supabase db reset` for a fresh development database.
3. Run `supabase test db` to execute `supabase/tests/rls.sql`.
4. Never rewrite an already-applied production migration; create a forward
   migration when deploying changes to an existing project.

## Drift gate

Before deployment, compare the eight shared tables, shared enum types, columns,
constraints, indexes, triggers, and shared trigger-function definitions from
schema-only dumps. Ignore only the authentication foreign-key target, Supabase
RLS policies, Supabase Storage objects, and cloud-only security/RPC functions.
