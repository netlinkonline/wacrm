import { NextResponse } from "next/server";

import { requirePlatformRole } from "@/lib/auth/platform";
import { toErrorResponse } from "@/lib/auth/account";
import { supabaseAdmin } from "@/lib/flows/admin-client";

export async function GET(request: Request) {
  try {
    await requirePlatformRole(["super_admin", "billing_admin", "technical_admin"]);

    const url = new URL(request.url);
    const rawPage = Number(url.searchParams.get("page") ?? "1");
    const rawPageSize = Number(url.searchParams.get("pageSize") ?? "25");
    const page = Number.isFinite(rawPage) ? Math.max(1, Math.floor(rawPage)) : 1;
    const pageSize = Number.isFinite(rawPageSize)
      ? Math.min(100, Math.max(1, Math.floor(rawPageSize)))
      : 25;

    const admin = supabaseAdmin();
    const from = (page - 1) * pageSize;
    const to = from + pageSize - 1;

    const { data: accounts, error, count } = await admin
      .from("accounts")
      .select("id, name, owner_user_id, created_at", { count: "exact" })
      .order("created_at", { ascending: false })
      .range(from, to);

    if (error) {
      console.error("[GET /api/admin/tenants] account query:", error);
      return NextResponse.json({ error: "Could not load customer organizations" }, { status: 500 });
    }

    const accountIds = (accounts ?? []).map((account) => account.id);
    const { data: subscriptions, error: subscriptionError } = accountIds.length
      ? await admin
          .from("whp_subscriptions")
          .select("id, account_id, plan_id, status, whmcs_client_id, whmcs_service_id, next_due_at, last_synced_at")
          .in("account_id", accountIds)
      : { data: [], error: null };

    if (subscriptionError) {
      console.error("[GET /api/admin/tenants] subscription query:", subscriptionError);
      return NextResponse.json({ error: "Could not load subscription records" }, { status: 500 });
    }

    const subscriptionByAccount = new Map(
      (subscriptions ?? []).map((subscription) => [subscription.account_id, subscription]),
    );

    return NextResponse.json({
      page,
      pageSize,
      total: count ?? 0,
      tenants: (accounts ?? []).map((account) => ({
        ...account,
        subscription: subscriptionByAccount.get(account.id) ?? null,
      })),
    });
  } catch (error) {
    return toErrorResponse(error);
  }
}
