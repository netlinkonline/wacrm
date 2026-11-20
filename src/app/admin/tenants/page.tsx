import Link from "next/link";
import { redirect } from "next/navigation";

import { requirePlatformRole } from "@/lib/auth/platform";
import { supabaseAdmin } from "@/lib/flows/admin-client";

export const dynamic = "force-dynamic";

export default async function PlatformTenantsPage() {
  try {
    await requirePlatformRole(["super_admin", "billing_admin", "technical_admin"]);
  } catch {
    redirect("/dashboard");
  }

  const admin = supabaseAdmin();
  const { data: accounts, error } = await admin
    .from("accounts")
    .select("id, name, owner_user_id, created_at")
    .order("created_at", { ascending: false })
    .limit(100);

  if (error) {
    console.error("[/admin/tenants] accounts:", error);
    return <main className="mx-auto max-w-6xl p-6"><h1 className="text-2xl font-semibold">Customer organizations</h1><p className="mt-3 text-sm text-destructive">Could not load organizations.</p></main>;
  }

  const ids = (accounts ?? []).map((account) => account.id);
  const { data: subscriptions, error: subscriptionError } = ids.length
    ? await admin
        .from("whp_subscriptions")
        .select("account_id, status, whmcs_service_id, next_due_at")
        .in("account_id", ids)
    : { data: [], error: null };

  if (subscriptionError) {
    console.error("[/admin/tenants] subscriptions:", subscriptionError);
  }

  const byAccount = new Map((subscriptions ?? []).map((row) => [row.account_id, row]));

  return (
    <main className="mx-auto max-w-6xl space-y-6 p-6">
      <div className="flex items-center gap-3">
        <Link href="/admin" className="text-sm text-muted-foreground hover:text-foreground">Platform Admin</Link>
        <span className="text-muted-foreground">/</span>
        <h1 className="text-2xl font-semibold tracking-tight text-foreground">Customer organizations</h1>
      </div>
      <p className="text-sm text-muted-foreground">Showing the 100 most recently created organizations.</p>
      <div className="overflow-x-auto rounded-xl border border-border bg-card">
        <table className="w-full min-w-[760px] text-left text-sm">
          <thead className="border-b border-border bg-muted/40 text-xs uppercase tracking-wide text-muted-foreground">
            <tr>
              <th className="px-4 py-3 font-medium">Organization</th>
              <th className="px-4 py-3 font-medium">Account ID</th>
              <th className="px-4 py-3 font-medium">WHMCS Service</th>
              <th className="px-4 py-3 font-medium">Subscription</th>
              <th className="px-4 py-3 font-medium">Next due</th>
              <th className="px-4 py-3 font-medium">Created</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {(accounts ?? []).map((account) => {
              const subscription = byAccount.get(account.id);
              return (
                <tr key={account.id} className="align-top">
                  <td className="px-4 py-3 font-medium text-foreground">{account.name}</td>
                  <td className="px-4 py-3 font-mono text-xs text-muted-foreground">{account.id}</td>
                  <td className="px-4 py-3 text-muted-foreground">{subscription?.whmcs_service_id ?? "Not linked"}</td>
                  <td className="px-4 py-3">
                    <span className="rounded-full border border-border px-2 py-1 text-xs capitalize text-foreground">{subscription?.status ?? "Unprovisioned"}</span>
                  </td>
                  <td className="px-4 py-3 text-muted-foreground">{subscription?.next_due_at ? new Date(subscription.next_due_at).toLocaleDateString() : "—"}</td>
                  <td className="px-4 py-3 text-muted-foreground">{new Date(account.created_at).toLocaleDateString()}</td>
                </tr>
              );
            })}
            {(accounts ?? []).length === 0 && (
              <tr><td colSpan={6} className="px-4 py-10 text-center text-muted-foreground">No customer organizations found.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </main>
  );
}
