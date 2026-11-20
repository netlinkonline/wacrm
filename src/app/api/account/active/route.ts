import { NextResponse } from "next/server";
import { cookies } from "next/headers";

import { createClient } from "@/lib/supabase/server";
import { isAccountRole } from "@/lib/auth/roles";

const ACTIVE_ACCOUNT_COOKIE = "wacrm_active_account";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function GET() {
  const supabase = await createClient();
  const { data: { user }, error: authError } = await supabase.auth.getUser();

  if (authError || !user) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const { data: memberships, error: membershipError } = await supabase
    .from("account_memberships")
    .select("account_id, role")
    .eq("user_id", user.id)
    .eq("status", "active")
    .order("created_at", { ascending: true });

  if (membershipError) {
    console.error("[GET /api/account/active] memberships:", membershipError);
    return NextResponse.json({ error: "Could not load organizations" }, { status: 500 });
  }

  const validMemberships = (memberships ?? []).filter(
    (membership) => typeof membership.account_id === "string" && isAccountRole(membership.role),
  );

  if (validMemberships.length === 0) {
    return NextResponse.json({ accounts: [] });
  }

  const accountIds = validMemberships.map((membership) => membership.account_id);
  const { data: accounts, error: accountsError } = await supabase
    .from("accounts")
    .select("id, name")
    .in("id", accountIds)
    .order("name", { ascending: true });

  if (accountsError) {
    console.error("[GET /api/account/active] accounts:", accountsError);
    return NextResponse.json({ error: "Could not load organizations" }, { status: 500 });
  }

  const roleByAccount = new Map(validMemberships.map((membership) => [membership.account_id, membership.role]));
  const cookieStore = await cookies();
  const selectedId = cookieStore.get(ACTIVE_ACCOUNT_COOKIE)?.value ?? null;

  return NextResponse.json({
    accounts: (accounts ?? []).map((account) => ({
      id: account.id,
      name: account.name,
      role: roleByAccount.get(account.id),
      active: account.id === selectedId,
    })),
  });
}

export async function POST(request: Request) {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
  }

  const accountId =
    body && typeof body === "object" && "accountId" in body
      ? (body as { accountId?: unknown }).accountId
      : null;

  if (typeof accountId !== "string" || !UUID_RE.test(accountId)) {
    return NextResponse.json({ error: "A valid accountId is required" }, { status: 400 });
  }

  const supabase = await createClient();
  const { data: { user }, error: authError } = await supabase.auth.getUser();

  if (authError || !user) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  // Never trust the requested account ID. Prove active membership
  // for this authenticated user before changing the selector cookie.
  const { data: membership, error: membershipError } = await supabase
    .from("account_memberships")
    .select("account_id")
    .eq("account_id", accountId)
    .eq("user_id", user.id)
    .eq("status", "active")
    .maybeSingle();

  if (membershipError) {
    console.error("[POST /api/account/active] membership:", membershipError);
    return NextResponse.json({ error: "Could not verify organization access" }, { status: 500 });
  }
  if (!membership) {
    return NextResponse.json({ error: "You are not an active member of this organization" }, { status: 403 });
  }

  const cookieStore = await cookies();
  cookieStore.set(ACTIVE_ACCOUNT_COOKIE, membership.account_id, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    maxAge: 60 * 60 * 24 * 30,
  });

  return NextResponse.json({ success: true, accountId: membership.account_id });
}
