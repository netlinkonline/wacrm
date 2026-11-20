# WACRM account and authorization audit — WHP

Audit date: 2026-11-21  
Audited branch baseline: `whp-saas-foundation` at `6dbeb5bf94d4cf01be351272d0d45b64b1a684d4`

## Findings from source

### 1. Existing account model is already shared-workspace multi-tenancy

Migration `017_account_sharing.sql` introduced:
- `accounts` as the shared workspace boundary.
- `profiles.account_id` and `profiles.account_role` as the membership source of truth.
- `is_account_member(account_id, min_role)` as the RLS helper.
- `account_id` on the main business tables and account-scoped RLS policies.
- A unique index `idx_accounts_one_per_owner` on `accounts(owner_user_id)`.

The same migration explicitly describes its design as one account per user and stores one account role on the user's profile. This is a hard incompatibility with the WHP requirement that one login can belong to several customer organizations.

### 2. Current web session context assumes exactly one account

`src/lib/auth/account.ts` loads the user's `profiles.account_id` and `profiles.account_role`, then loads one `accounts` row. `AccountContext` exposes a single `accountId` and one role. Existing routes rely on `getCurrentAccount()` and `requireRole()`.

We must not replace this context in one step. Introduce an explicit selected-workspace context while preserving the existing default-account behavior during migration.

### 3. Public API keys are account-scoped

`src/lib/auth/api-context.ts` authenticates a hashed API key and resolves one `account_id`. It uses a service-role Supabase client and documents that every downstream query must explicitly filter by that account. New tenant identity must be resolved from the key record, never a caller-supplied tenant ID.

### 4. Existing membership management has single-account assumptions

The current invitation/redeem and member-removal RPCs update `profiles.account_id`. Migration `047_account_membership_integrity.sql` and `055_authz_membership_holes.sql` add important membership/privilege safeguards. Those functions must be reviewed and redesigned before allowing multi-organization membership; otherwise a user joining a second tenant could be moved out of the first or account isolation could be weakened.

### 5. Existing WhatsApp config model is restrictive

Migration 017 changes `whatsapp_config` to a unique `account_id`, documenting one WhatsApp number per account. WHP requires multiple WABAs and phone numbers per tenant. This needs a normalized WABA/phone-number model and a compatibility plan for the existing config row. Do not simply drop the unique constraint until every read/write route, webhook, campaign and automation is migrated.

## Recommended compatibility design

1. Treat each existing WACRM `accounts` row as the initial WHP customer workspace/tenant boundary. Avoid maintaining two competing organization identities unless a specific product requirement proves necessary.
2. Retain `accounts.id` as the stable tenant/workspace ID for existing domain rows. Add a one-to-one SaaS metadata/subscription mapping table keyed by `account_id` for plan, WHMCS service and platform lifecycle.
3. Introduce a true many-to-many `account_memberships` table keyed by `(account_id,user_id)`, with role, status, invitation and audit fields. Migrate existing `profiles.account_id/account_role` into one membership row per user.
4. Keep `profiles.account_id` temporarily as a default/last-selected account for backwards compatibility. Do not use it as the sole authorization source after the membership cutover.
5. Add server-verified active-account resolution. A user may select only an account for which an active membership exists. Never trust an account ID from request body/query alone.
6. Update RLS helper `is_account_member` to consult `account_memberships`; keep its role hierarchy and regression tests. Preserve legacy profile fields until all routes and triggers are migrated.
7. Keep API keys scoped to exactly one account/tenant. A key must not inherit all organizations of its creator.
8. Introduce normalized `whatsapp_business_accounts` and `whatsapp_phone_numbers` linked to account ID. Migrate existing `whatsapp_config` safely and retain compatibility until all Meta routes use the normalized tables.
9. Add platform admin roles separately from customer membership roles. Support access must be explicit, time-limited and audited.

## Impacted code areas

- `src/lib/auth/account.ts`, `src/lib/auth/roles.ts`, account API routes and invitation RPCs.
- Every route that calls `getCurrentAccount()` / `requireRole()`.
- Account RLS policies and storage object policies.
- API-key context and API-key creation/rotation.
- Meta webhook tenant resolution, WhatsApp config, templates, broadcasts, automations and flows.
- Background cron/worker routes that currently use account IDs.
- Frontend account switcher, invitation and member management.

## Decision on migration 061

`061_whp_saas_foundation.sql` is an additive prototype for the WHP SaaS metadata layer. It is **not approved for application** because the source audit indicates the canonical tenant identity should likely be the existing WACRM `accounts.id`. Before applying any migration, consolidate the schema around that identity and replace the prototype's separate `whp_tenants` identity with a clear account-to-SaaS mapping or an approved organization model.

## Next implementation sequence

1. Write migration design for many-to-many account membership and SaaS metadata attached to `accounts`.
2. Add pure TypeScript tenant/account selection and role-resolution helpers with unit tests.
3. Add migration tests and RLS tests for two accounts, one user in both, role differences per account, revoked membership and direct ID tampering.
4. Only after those tests pass, update API context and UI account switching.
5. Normalize WABA and phone numbers after the tenant boundary is stable.

## Release safety

No database migration in this audit has been applied to a live or staging database. Do not deploy `061_whp_saas_foundation.sql` until the revised canonical-identity decision and migration tests are complete.
