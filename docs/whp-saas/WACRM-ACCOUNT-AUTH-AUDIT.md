# WACRM account and authorization audit — WHP

Audit date: 2026-11-21  
Source baseline: WACRM main commit `6dbeb5bf94d4cf01be351272d0d45b64b1a684d4`

## Source findings

1. Migration 017 introduced shared workspace tenancy through `accounts`, `profiles.account_id/account_role`, and `is_account_member()`. It intentionally enforced one account per user and one WhatsApp number per account.
2. `getCurrentAccount()` originally resolved only the profile's single default account.
3. API keys are account-scoped and use a service-role client. Every API route must continue to filter by the account resolved from the key; request-supplied account IDs must never override it.
4. Legacy invitation, member removal and ownership functions moved users between profiles/account IDs. That behavior is incompatible with multi-organization membership.
5. `whatsapp_config` is unique by account and must be normalized before multi-WABA/multi-number functionality is enabled.

## Implemented in the WHP branch

- Migration 061 now uses existing `accounts.id` as the canonical tenant ID. It adds and backfills `account_memberships`, replaces `is_account_member()` to authorize through active memberships, removes the one-account-per-owner index, and adds platform roles, plans, WHMCS subscription mirror, usage ledger and audit log.
- Migration 062 adds membership-aware invitation creation/redemption, role changes, member removal and ownership transfer. Redeeming an invitation adds a membership and does not delete or move the user's existing workspace.
- `getCurrentAccount()` reads an HTTP-only active-account selector cookie and revalidates it against the authenticated user's active membership on every request. Without a selector, it falls back to the legacy profile default.
- `/api/account/active` lists the authenticated user's active organizations and only accepts a selection after verifying membership.
- `AccountSwitcher` is integrated into the dashboard sidebar.

## Compatibility and rollout notes

- `profiles.account_id/account_role` are retained as a legacy default-account pointer. They are not the new multi-membership source of truth.
- Legacy WACRM member-management endpoints and RPCs still require a full migration to the new account-specific membership operations before all multi-org administration flows are considered complete.
- Existing `whatsapp_config` remains one-per-account. Multiple WABAs/phone numbers are not yet implemented.
- The new migrations and application code are committed but have not been run against a live staging Supabase database in this environment. They must not be applied to production without migration-chain, SQL, RLS, and application integration tests.

## Remaining work

1. Migrate member invitation/list/role/removal UI and APIs to account-specific membership operations.
2. Add database integration tests for two accounts, one user in both, per-account roles, revoked membership, owner transfer and cross-account access denial.
3. Normalize WABA and phone-number tables and safely migrate the legacy WhatsApp config.
4. Add WHP Super Admin authorization and administration screens.
5. Add plan entitlement enforcement, WHMCS provisioning and usage reconciliation.
