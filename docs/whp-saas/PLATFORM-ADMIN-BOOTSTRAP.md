# First WHP platform administrator

Platform roles are deliberately not self-service and cannot be granted from the customer dashboard.

After migrations 061–063 have been applied to an isolated staging Supabase project:

1. Create the WHP operator login through the normal Supabase Auth signup flow.
2. Open the Supabase SQL Editor for that staging project.
3. Run the following statement with the exact email address of the operator account:

```sql
INSERT INTO public.whp_platform_roles (user_id, role, granted_by)
SELECT id, 'super_admin', id
FROM auth.users
WHERE lower(email) = lower('YOUR-ADMIN-EMAIL')
ON CONFLICT (user_id, role)
DO UPDATE SET revoked_at = NULL, granted_at = now();
```

4. Confirm exactly one row was inserted or reactivated:

```sql
SELECT u.email, r.role, r.granted_at, r.revoked_at
FROM public.whp_platform_roles r
JOIN auth.users u ON u.id = r.user_id
WHERE lower(u.email) = lower('YOUR-ADMIN-EMAIL');
```

5. Sign in again and open `/admin`.

Replace the placeholder with the actual operator email before executing. Do not put this SQL in a public API route, client component, seed file committed with a real email, or customer-facing setup wizard. Keep the first super-admin grant as a controlled database operation. Revoke access by setting `revoked_at = now()`; do not delete the audit history.

For production, use a separately controlled operator identity and document who approved each platform-role grant.
