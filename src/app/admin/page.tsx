import Link from "next/link";
import { redirect } from "next/navigation";

import { requirePlatformRole } from "@/lib/auth/platform";
import { supabaseAdmin } from "@/lib/flows/admin-client";

export const dynamic = "force-dynamic";

function StatCard({ label, value }: { label: string; value: number }) {
  return (
    <div className="rounded-xl border border-border bg-card p-5">
      <p className="text-sm text-muted-foreground">{label}</p>
      <p className="mt-2 text-3xl font-semibold tracking-tight text-foreground">{value.toLocaleString()}</p>
    </div>
  );
}

export default async function PlatformAdminPage() {
  try {
    await requirePlatformRole(["super_admin", "billing_admin", "technical_admin"]);
  } catch {
    redirect("/dashboard");
  }

  const admin = supabaseAdmin();
  const [tenants, subscriptions, activeSubscriptions, plans] = await Promise.all([
    admin.from("accounts").select("id", { count: "exact", head: true }),
    admin.from("whp_subscriptions").select("id", { count: "exact", head: true }),
    admin.from("whp_subscriptions").select("id", { count: "exact", head: true }).eq("status", "active"),
    admin.from("whp_plans").select("id", { count: "exact", head: true }).eq("is_active", true),
  ]);

  const failed = [tenants, subscriptions, activeSubscriptions, plans].some((result) => result.error);
  if (failed) {
    return (
      <main className="mx-auto max-w-6xl p-6">
        <h1 className="text-2xl font-semibold">WHP Platform Administration</h1>
        <p className="mt-3 text-sm text-destructive">Platform statistics could not be loaded. Verify that migrations 061–063 have been applied to the configured staging database.</p>
      </main>
    );
  }

  return (
    <main className="mx-auto max-w-6xl space-y-8 p-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <p className="text-xs font-semibold uppercase tracking-[0.18em] text-primary">WHP Control Plane</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight text-foreground">Platform Administration</h1>
          <p className="mt-1 text-sm text-muted-foreground">Manage customer organizations and SaaS subscriptions.</p>
        </div>
        <Link href="/admin/tenants" className="rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:opacity-90">
          Manage organizations
        </Link>
      </div>

      <section className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard label="Customer organizations" value={tenants.count ?? 0} />
        <StatCard label="Subscription records" value={subscriptions.count ?? 0} />
        <StatCard label="Active subscriptions" value={activeSubscriptions.count ?? 0} />
        <StatCard label="Active plans" value={plans.count ?? 0} />
      </section>

      <section className="rounded-xl border border-border bg-card p-5">
        <h2 className="font-semibold text-foreground">Platform modules</h2>
        <div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {[
            ["Customer organizations", "/admin/tenants"],
            ["Plans and entitlements", "/admin/plans"],
            ["Subscriptions and billing", "/admin/subscriptions"],
            ["Usage and limits", "/admin/usage"],
            ["Platform access", "/admin/access"],
            ["Audit events", "/admin/audit"],
          ].map(([label, href]) => (
            <Link key={href} href={href} className="rounded-lg border border-border px-4 py-3 text-sm text-foreground transition-colors hover:bg-muted">
              {label}
              <span className="ml-2 text-xs text-muted-foreground">Foundation in progress</span>
            </Link>
          ))}
        </div>
      </section>
    </main>
  );
}
