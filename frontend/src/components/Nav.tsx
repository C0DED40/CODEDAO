"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useState } from "react";
import { ListIcon, XIcon } from "@phosphor-icons/react";
import { NAV } from "@/lib/site";

export function Nav() {
  const path = usePathname();
  const [open, setOpen] = useState(false);

  return (
    <header
      className="sticky top-0 border-b border-line bg-bg/90"
      style={{ zIndex: 50 }}
    >
      <div className="mx-auto flex h-16 max-w-[1400px] items-center justify-between px-4 md:px-8">
        <Link
          href="/"
          className="font-display text-sm font-bold tracking-[0.18em] text-accent uppercase"
          onClick={() => setOpen(false)}
        >
          CODE.DAO
        </Link>

        <nav className="hidden items-center gap-8 lg:flex">
          {NAV.map((item) => {
            const active = path === item.href;
            return (
              <Link
                key={item.href}
                href={item.href}
                className={`text-xs uppercase tracking-[0.18em] transition-colors duration-300 ease-[cubic-bezier(0.16,1,0.3,1)] ${
                  active ? "text-accent" : "text-muted hover:text-fg"
                }`}
              >
                {item.label}
              </Link>
            );
          })}
        </nav>

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
        <div
          className="border-t border-line bg-bg px-4 py-8 lg:hidden"
          style={{ zIndex: 60 }}
        >
          <nav className="flex flex-col gap-5">
            {NAV.map((item) => (
              <Link
                key={item.href}
                href={item.href}
                onClick={() => setOpen(false)}
                className="text-lg uppercase tracking-[0.16em] text-fg"
              >
                {item.label}
              </Link>
            ))}
            <Link
              href="/app/stake"
              onClick={() => setOpen(false)}
              className="mt-4 inline-flex w-fit border border-accent bg-accent px-5 py-3 text-sm uppercase tracking-[0.14em] text-bg"
            >
              Stake CODE
            </Link>
          </nav>
        </div>
      ) : null}
    </header>
  );
}
