"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { ListIcon, XIcon } from "@phosphor-icons/react";
import { Connect } from "@/components/Connect";
import { MobileSheet } from "@/components/MobileSheet";
import { APP_NAV } from "@/lib/app";

export function AppNav() {
  const path = usePathname();
  const [open, setOpen] = useState(false);

  useEffect(() => {
    setOpen(false);
  }, [path]);

  return (
    <>
      <header
        className="sticky top-0 border-b border-line bg-bg/90 pt-[env(safe-area-inset-top,0px)]"
        style={{ zIndex: 50 }}
      >
        <div className="mx-auto flex h-14 max-w-[1400px] items-center justify-between gap-3 px-4 md:h-16 md:px-8">
          <Link
            href="/app"
            className="font-display shrink-0 text-[13px] font-bold tracking-[0.12em] text-accent uppercase md:text-sm md:tracking-[0.18em]"
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

          <div className="flex items-center gap-2">
            <Connect />
            <button
              type="button"
              className="grid size-11 place-items-center text-accent lg:hidden"
              aria-expanded={open}
              aria-label={open ? "Close menu" : "Open menu"}
              onClick={() => setOpen((v) => !v)}
            >
              {open ? <XIcon size={22} weight="bold" /> : <ListIcon size={22} weight="bold" />}
            </button>
          </div>
        </div>
      </header>

      <MobileSheet open={open} onClose={() => setOpen(false)}>
        <nav className="flex flex-col gap-1">
          <Link
            href="/app"
            onClick={() => setOpen(false)}
            className="flex min-h-12 items-center text-lg uppercase tracking-[0.16em]"
          >
            Desk
          </Link>
          {APP_NAV.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              onClick={() => setOpen(false)}
              className="flex min-h-12 items-center text-lg uppercase tracking-[0.16em] text-fg"
            >
              {item.label}
            </Link>
          ))}
        </nav>
      </MobileSheet>
    </>
  );
}
