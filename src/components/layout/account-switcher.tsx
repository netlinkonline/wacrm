"use client";

import { useCallback, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { ChevronsUpDown, Plus, UsersRound } from "lucide-react";

import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

type AccountOption = {
  id: string;
  name: string;
  role: "owner" | "admin" | "agent" | "viewer";
  active: boolean;
};

export function AccountSwitcher() {
  const router = useRouter();
  const [accounts, setAccounts] = useState<AccountOption[]>([]);
  const [activeId, setActiveId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [switching, setSwitching] = useState(false);

  const loadAccounts = useCallback(async () => {
    try {
      const response = await fetch("/api/account/active", { cache: "no-store" });
      if (!response.ok) return;
      const payload = (await response.json()) as { accounts?: AccountOption[] };
      const rows = payload.accounts ?? [];
      setAccounts(rows);
      setActiveId(rows.find((row) => row.active)?.id ?? null);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void loadAccounts();
  }, [loadAccounts]);

  async function selectAccount(accountId: string) {
    if (accountId === activeId || switching) return;
    setSwitching(true);
    try {
      const response = await fetch("/api/account/active", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ accountId }),
      });
      if (!response.ok) {
        const payload = (await response.json().catch(() => ({}))) as { error?: string };
        throw new Error(payload.error ?? "Could not switch organization");
      }
      setActiveId(accountId);
      await loadAccounts();
      router.refresh();
    } catch (error) {
      console.error("[AccountSwitcher] switch failed:", error);
    } finally {
      setSwitching(false);
    }
  }

  if (loading || accounts.length === 0) return null;

  const active = accounts.find((account) => account.id === activeId) ?? accounts[0];

  return (
    <div className="border-b border-border px-3 py-2">
      <DropdownMenu>
        <DropdownMenuTrigger
          disabled={switching}
          className="flex w-full items-center gap-2 rounded-lg border border-border bg-background px-3 py-2 text-left transition-colors hover:bg-muted disabled:opacity-60"
          aria-label="Switch organization"
        >
          <UsersRound className="size-4 shrink-0 text-muted-foreground" />
          <span className="min-w-0 flex-1">
            <span className="block truncate text-xs font-medium text-foreground">
              {active.name}
            </span>
            <span className="block text-[10px] capitalize text-muted-foreground">
              {switching ? "Switching…" : active.role}
            </span>
          </span>
          <ChevronsUpDown className="size-3.5 shrink-0 text-muted-foreground" />
        </DropdownMenuTrigger>
        <DropdownMenuContent align="start" side="right" className="min-w-60">
          <div className="px-2 py-1.5 text-xs font-medium text-muted-foreground">
            Your organizations
          </div>
          {accounts.map((account) => (
            <DropdownMenuItem
              key={account.id}
              onClick={() => void selectAccount(account.id)}
              className="flex items-center justify-between gap-3"
            >
              <span className="min-w-0 truncate">{account.name}</span>
              <span className="shrink-0 text-[10px] capitalize text-muted-foreground">
                {account.role}{account.id === activeId ? " · Active" : ""}
              </span>
            </DropdownMenuItem>
          ))}
          <DropdownMenuSeparator />
          <DropdownMenuItem disabled>
            <Plus className="size-4" />
            Create organization (coming soon)
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </div>
  );
}
