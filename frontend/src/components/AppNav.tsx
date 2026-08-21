"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useState } from "react";
import { ListIcon, XIcon } from "@phosphor-icons/react";
import { Connect } from "@/components/Connect";
import { APP_NAV } from "@/lib/app";

export function AppNav() {
  const path = usePathname();
  const [open, setOpen] = useState(false);

  return (
    <header className="sticky top-0 border-b border-line bg-bg/90" style={{ zIndex: 50 }}>
      <div className="mx-auto flex h-16 max-w-[1400px] items-center justify-between px-4 md:px-8">
        <Link
          href="/app"
          className="font-display text-sm font-bold tracking-[0.18em] text-accent uppercase"
          onClick={() => setOpen(false)}
        >
          CODE.DAO
        </Link>

        <nav className="hidden items-center gap-10 lg:flex">
          {APP_NAV.map((item) => {
            const active = path === item.href || path.startsWith(`${item.href}/`);
            return (
              <Link
                key={item.href}
                href={item.href}
                className={`text-xs uppercase tracking-[0.18em] ${
                  active ? "text-accent underline underline-offset-8" : "text-muted hover:text-fg"
                }`}
              >
                {item.label}
              </Link>
            );
          })}
        </nav>

        <div className="hidden lg:block">
          <Connect />
        </div>

        <button
          type="button"
          className="grid size-10 place-items-center text-accent lg:hidden"
          aria-expanded={open}
          aria-label={open ? "Close menu" : "Open menu"}
          onClick={() => setOpen((v) => !v)}
        >
          {open ? <XIcon size={22} weight="bold" /> : <ListIcon size={22} weight="bold" />}
        </button>
      </div>

      {open ? (
        <div className="border-t border-line bg-bg px-4 py-8 lg:hidden">
          <nav className="flex flex-col gap-5">
            <Link href="/app" onClick={() => setOpen(false)} className="text-lg uppercase tracking-[0.16em]">
              Desk
            </Link>
            {APP_NAV.map((item) => (
              <Link
                key={item.href}
                href={item.href}
                onClick={() => setOpen(false)}
                className="text-lg uppercase tracking-[0.16em] text-fg"
              >
                {item.label}
              </Link>
            ))}
            <div className="mt-4">
              <Connect />
            </div>
          </nav>
        </div>
      ) : null}
    </header>
  );
}
