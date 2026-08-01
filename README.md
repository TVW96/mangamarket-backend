# MangaMarketplace Backend

NestJS and PostgreSQL backend foundation for a marketplace where users list
individual physical manga copies or collaboratively curate multi-seller
collector sets.

This repository currently contains the Phase 1 database foundation, matching
local and Supabase migrations, database integrity rules, RLS policies, Storage
policies, and database tests. Full authentication endpoints, marketplace REST
controllers, image-upload endpoints, and purchasing workflows belong to later
phases.

## Domain model

The database keeps the catalog, physical inventory, and marketplace offers
separate:

- A `CatalogProduct` (`catalog_products`) contains shared metadata about a manga
  release. It is not stock and does not identify a seller-owned copy.
- An `InventoryItem` (`inventory_items`) is exactly one physical copy with one
  current owner, condition, and availability. Multiple physical copies may
  reference the same catalog product.
- A `Listing` (`listings`) is one offer and checkout unit assembled by a
  curator. It connects to physical copies through `listing_items`; the curator
  does not have to own every included copy.
- A `ListingContributor` (`listing_contributors`) records one contributing
  seller's consent to the listing's current terms and preserves where future
  proceeds are attributable.

The shared domain tables are:

- `profiles`
- `user_roles`
- `catalog_products`
- `inventory_items`
- `listings`
- `listing_contributors`
- `listing_items`
- `media_assets`

Each resource has its own UUID. Catalog-product, inventory-item, listing,
contributor, listing-item, and media identifiers must never be reused across
resource types.

## Collaborative collector listings

An available physical copy may participate in an individual listing and in one
or more collector-set listings at the same time. The database therefore keeps
only the within-listing uniqueness rule on `(listing_id, item_id)`; it does not
make `item_id` globally unique across active listings. Publishing a listing does
not reserve its items.

The listing's `curator_id` identifies the user assembling the offer. Every
physical item is linked to a `listing_contributors` row for its actual owner.
Contributors accept, reject, or withdraw consent for a specific
`terms_version`. A material price, currency, type, or composition change must
advance that version and require current consent again. `proceeds_amount` is an
optional proposed gross seller allocation while a draft is being assembled.
Before publication, every contributor needs an allocation and those amounts
must sum to the listing price. Fee calculation, settlement, payment, and payout
remain Phase 2 work.

An actionable `SINGLE` contains exactly one accepted physical copy in the state
required by its listing (`AVAILABLE` for active, `RESERVED` for reserved). An
actionable `BUNDLE` contains at least two and may combine copies owned by
different sellers. Drafts may be incomplete while their curator assembles the
set and obtains consent.

## Local and Supabase deployments

Both deployments use identical shared table columns, types, constraints,
indexes, and integrity triggers. Authentication is the intentional difference:

| Deployment | Authentication relationship |
| --- | --- |
| Local PostgreSQL | `profiles.auth_user_id -> public.auth_users.id` |
| Supabase | `profiles.auth_user_id -> auth.users.id` |

Supabase additionally provides RLS and Storage policies. Local authorization is
enforced through NestJS guards and server-side transactions.

See [database/SCHEMA_PARITY.md](database/SCHEMA_PARITY.md) for the complete
parity contract and approved platform-specific differences.

## Prerequisites

- Node.js 20 or newer
- npm
- PostgreSQL 15 or newer
- `psql` and `createdb`
- Supabase CLI 2.x for cloud migration work
- Docker Desktop when running the local Supabase stack

## Install dependencies

```bash
npm install
```

## Create the local database

Create an empty PostgreSQL database and set its connection URL:

```bash
createdb manga_marketplace_local
export DATABASE_URL="postgresql://localhost:5432/manga_marketplace_local"
```

Apply the baseline and collaborative-listing migrations in order:

```bash
psql -v ON_ERROR_STOP=1 "$DATABASE_URL" \
  -f database/migrations/001_phase1_marketplace.sql
psql -v ON_ERROR_STOP=1 "$DATABASE_URL" \
  -f database/migrations/002_collaborative_collector_listings.sql
```

The baseline migration installs the `citext`, `pgcrypto`, and `pg_trgm`
extensions. The database user applying it must be permitted to create
extensions and the `extensions` schema.

## Test the local database

Run the database smoke and integrity tests:

```bash
psql -v ON_ERROR_STOP=1 "$DATABASE_URL" \
  -f database/tests/phase1_schema.sql
```

The test runs inside a transaction and rolls back its fixtures. It validates:

- Local authentication users, profiles, and roles.
- Catalog products versus independently owned physical inventory copies.
- Single-listing and collaborative collector-set relationships.
- Contributor identity, physical-item ownership, and current-terms consent.
- A valid contributor allocation split sums to the actionable listing price.
- Valid single and multi-seller bundle cardinality.
- The same available physical item may belong to several active listings.
- Actionable listing terms and composition are immutable.
- Unbacked `SOLD` transitions and non-atomic inventory changes are rejected.
- A valid media row follows the type, bucket, path, and target contract.
- Automatic `updated_at` maintenance.

## Run the NestJS application

```bash
# Development watch mode
npm run start:dev

# Standard development start
npm run start

# Production build and start
npm run build
npm run start:prod
```

The current NestJS modules are starter scaffolding. Database integration,
Prisma, environment validation, and the full domain services still need to be
wired into the application layer.

## Run application tests

```bash
# Unit tests
npm test

# End-to-end tests
npm run test:e2e

# Coverage
npm run test:cov
```

## Supabase local development

The deployable Supabase project is under `supabase/`.

Start the local Supabase stack:

```bash
supabase start
```

Recreate the local Supabase database and apply all migrations:

```bash
supabase db reset
```

Run the pgTAP RLS suite:

```bash
supabase test db
```

The Supabase tests cover profile ownership, privileged roles, private inventory
data, public marketplace projections, curator/contributor boundaries, media
rules, and Storage path ownership.

Stop the local stack when finished:

```bash
supabase stop
```

## Deploy to a Supabase project

Authenticate and link the repository to the intended project:

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
```

Review pending migrations before deployment:

```bash
supabase migration list
supabase db diff --linked
```

Push the migrations:

```bash
supabase db push
```

Important deployment rules:

- Never rewrite a migration that has already been applied remotely. Add a new
  forward migration instead.
- Never put service-role keys or production credentials in the repository.
- Keep the Supabase service-role key on trusted server infrastructure only.
- Run `supabase test db` against a disposable or local database before pushing.
- Back up production data before applying destructive forward migrations.

## Supabase RLS behavior

- Public profile discovery uses the safe `public_profiles` projection, which
  omits the authentication-user identifier; base profile rows are owner-only.
- Users may update only their own profile.
- Users may read their own role assignments; only `DEVELOPER` or `ADMIN` users
  may manage roles.
- Catalog products are publicly readable unless soft-deleted.
- Inventory base rows are owner-only because `acquisition_price` and
  `condition_notes` are private.
- Public clients use `marketplace_inventory_items`, which omits private fields.
- Active listings and their item memberships are publicly readable.
- Curators manage their own draft listings and composition; contributing
  sellers may read participating listings and respond only to their own consent
  records.
- Contributor allocation and consent details are not anonymous public data.
- Sellers may modify only their own inventory and media; listing media belongs
  to the curator.
- Hard deletion is not granted through the client API; lifecycle changes use
  statuses and `deleted_at`.

Collaborative writes use narrow authenticated RPCs instead of raw junction-row
or lifecycle updates:

- `update_draft_listing` revises material draft terms and advances consent
  versioning.
- `propose_listing_item` and `remove_listing_item` manage draft composition.
- `update_draft_contributor_proceeds` revises a seller's proposed allocation.
- `respond_to_listing_contribution` records the physical owner's response.
- `publish_listing` validates and activates a fully accepted offer.
- `retire_listing` cancels or archives a nonterminal offer without rewriting
  terminal history.

## Supabase Storage

All buckets are private. Access is controlled by Storage RLS or signed URLs.

| Media type | Bucket | Required object path |
| --- | --- | --- |
| Avatar | `avatars` | `<profileId>/<filename>` |
| Product | `product-media` | `<productId>/<filename>` |
| Inventory item | `item-media` | `<itemId>/<filename>` |
| Listing | `listing-media` | `<listingId>/<filename>` |

The `media_assets` row must use the same bucket and resource identifier as its
Storage object path.

## Verify schema parity

Set URLs for initialized local and Supabase-compatible databases:

```bash
export LOCAL_DATABASE_URL="postgresql://localhost:5432/manga_marketplace_local"
export SUPABASE_DATABASE_URL="postgresql://postgres:password@localhost:54322/postgres"
```

Run the parity gate:

```bash
database/tests/verify_schema_parity.sh
```

The script compares shared enums, the eight shared tables, columns,
non-authentication constraints, indexes, triggers, and the trigger-function
definitions behind the integrity rules. It intentionally ignores the
authentication foreign-key target, Supabase RLS, Storage objects, and
cloud-only authorization/RPC functions.

## Database integrity rules

The database enforces these rules, using deferred commit-time checks for
multi-row integrity:

- An actionable `SINGLE` contains exactly one inventory item; an actionable
  `BUNDLE` contains at least two.
- In `DRAFT`, `ACTIVE`, and `RESERVED`, every listing item points to the
  contributor who currently owns that physical item. Terminal rows retain the
  seller snapshot even if ownership later transfers.
- Every actionable contributor has accepted the listing's current terms
  version, and every included item has the matching available/reserved state.
- Every actionable contributor has at least one item and a proceeds allocation;
  allocations sum to the listing price.
- A physical item may be present in several active listings while it remains
  `AVAILABLE`.
- At most one listing may reserve a given physical item.
- Terms and composition are immutable after a listing leaves `DRAFT`; revision
  requires a new draft and a fresh consent cycle.
- Phase 1 rejects listing and inventory transitions into `SOLD`; only the
  future order-backed purchase transaction may create sold state.

Regular users must never be given an application path that can grant
`DEVELOPER` or `ADMIN` roles.

## Phase 2 winning-purchase boundary

This Phase 1 repository does not implement checkout, orders, payment, sale, or
payout APIs. A database trigger rejects direct transitions into `SOLD`, and
changing an inventory status alone is not a valid purchase operation.

The future winning-purchase command must run as one transaction after payment
authorization. It must lock the selected listing and all constituent physical
items, revalidate current consent, ownership, and availability, claim the
complete set atomically, and mark only the selected listing sold. Every other
active listing containing any winning item must be archived or invalidated in
that same transition without deleting its membership history. A competing
bundle must never silently lose an item and remain live at its old price.

## Important files

| File | Purpose |
| --- | --- |
| `database/migrations/001_phase1_marketplace.sql` | Local PostgreSQL baseline schema |
| `database/migrations/002_collaborative_collector_listings.sql` | Local collaborative-listing forward migration |
| `database/tests/phase1_schema.sql` | Local database tests |
| `database/tests/verify_schema_parity.sh` | Local/Supabase parity gate |
| `database/SCHEMA_PARITY.md` | Canonical schema contract |
| `supabase/migrations/20260731120000_schema.sql` | Supabase baseline shared schema |
| `supabase/migrations/20260731121000_integrity_rls_storage.sql` | RLS and Storage overlay |
| `supabase/migrations/20260731122000_collaborative_collector_listings.sql` | Supabase collaborative-listing and RLS forward migration |
| `supabase/tests/rls.sql` | Supabase pgTAP tests |
| `supabase/config.toml` | Supabase CLI configuration |

## Current verification status

- NestJS unit tests and the production build pass.
- Earlier iterations of the ordered local migration, smoke suite, and populated
  legacy backfill passed on disposable PostgreSQL 15/18 instances.
- The final lock-order, terminal-history, reservation-exclusivity, and RPC/ACL
  refinements pass static source-parity and `git diff --check` review.
- The latest SQL regression and pgTAP runs still need execution against
  PostgreSQL/Supabase. This environment reached its database-execution credit
  limit before the final rerun; use the commands above before deployment.

## License

This project is private and currently uses the `UNLICENSED` package designation.
