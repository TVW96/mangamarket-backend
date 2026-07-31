# MangaMarketplace Schema Parity Contract

The Phase 1 Figma ERD and specification define one domain model with two
deployment adapters. Shared tables, columns, types, checks, foreign-key actions,
indexes, and integrity triggers must remain equivalent between the local and
Supabase migrations.

## Canonical files

- Local PostgreSQL: `database/migrations/001_phase1_marketplace.sql`
- Local smoke test: `database/tests/phase1_schema.sql`
- Supabase schema: `supabase/migrations/20260731120000_schema.sql`
- Supabase security/Storage: `supabase/migrations/20260731121000_integrity_rls_storage.sql`
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

No other physical schema difference is intentional.

## Shared domain tables

- `profiles`
- `user_roles`
- `catalog_products`
- `inventory_items`
- `listings`
- `listing_items`
- `media_assets`

Every resource has its own UUID. Catalog products describe releases;
inventory items describe seller-owned physical copies; listings contain those
copies through `listing_items`.

## Approved schema extensions beyond the minimum ERD

- Catalog creation provenance and soft deletion.
- Decimal volume numbers for special releases such as volume `0.5`.
- Listing title, description, ISO-shaped currency, sale timestamp, and soft deletion.
- Enumerated item conditions and media types.
- Media soft deletion and strict bucket/path-to-resource matching.

These extensions do not collapse or replace any entity required by the ERD.

## Protected information

- Authentication email is never duplicated in `profiles`.
- Local password hashes remain only in `auth_users`.
- Supabase password hashes and refresh tokens remain only in Supabase Auth.
- `inventory_items.acquisition_price` and `condition_notes` are seller-private.
- Supabase public reads use `marketplace_inventory_items`, which omits private fields.

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

1. `SINGLE` listings in publishable/historical states contain exactly one item.
2. `BUNDLE` listings in publishable/historical states contain at least two items.
3. Every listed inventory item belongs to the listing seller.
4. A physical item cannot appear in multiple active or reserved listings.
5. Active listings contain available inventory, reserved listings contain reserved
   inventory, and sold listings contain sold inventory.

NestJS commands must update listing and inventory states inside one transaction.
Regular users must never receive a database path that can grant `DEVELOPER` or
`ADMIN`; Supabase RLS independently enforces that rule in cloud deployments.

## Deployment and verification

### Local

1. Apply `001_phase1_marketplace.sql` to a fresh PostgreSQL database.
2. Run `database/tests/phase1_schema.sql` with `ON_ERROR_STOP=1`.
3. Run Prisma validation, generation, seeds, build, and Jest after Prisma is added.

### Supabase

1. Place the `supabase` directory at the Supabase CLI project root.
2. Run `supabase db reset` for a fresh development database.
3. Run `supabase test db` to execute `supabase/tests/rls.sql`.
4. Never rewrite an already-applied production migration; create a forward
   migration when deploying changes to an existing project.

## Drift gate

Before deployment, compare the seven shared tables from schema-only dumps. Ignore
only the authentication foreign-key target, Supabase RLS policies, Supabase
Storage objects, and cloud-only security helper functions.
