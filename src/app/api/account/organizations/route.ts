import { NextResponse } from "next/server";
import { cookies } from "next/headers";

import { createClient } from "@/lib/supabase/server";

const ACTIVE_ACCOUNT_COOKIE = "wacrm_active_account";

export async function POST(request: Request) {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
  }

  const name =
    body && typeof body === "object" && "name" in body
      ? (body as { name?: unknown }).name
      : null;

  if (typeof name !== "string" || name.trim().length < 2 || name.trim().length > 120) {
    return NextResponse.json({ error: "Organization name must contain 2 to 120 characters" }, { status: 400 });
  }

  const supabase = await createClient();
  const { data: { user }, error: authError } = await supabase.auth.getUser();
  if (authError || !user) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const { data: accountId, error } = await supabase.rpc("create_account_for_user", {
    p_name: name.trim(),
  });

  if (error || typeof accountId !== "string") {
    console.error("[POST /api/account/organizations] create error:", error);
    return NextResponse.json({ error: "Could not create organization" }, { status: 500 });
  }

  const cookieStore = await cookies();
  cookieStore.set(ACTIVE_ACCOUNT_COOKIE, accountId, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    maxAge: 60 * 60 * 24 * 30,
  });

  return NextResponse.json({ success: true, accountId }, { status: 201 });
}
