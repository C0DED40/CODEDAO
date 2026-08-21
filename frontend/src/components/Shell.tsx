"use client";

import { usePathname } from "next/navigation";
import { AppNav } from "@/components/AppNav";
import { Footer } from "@/components/Footer";
import { Nav } from "@/components/Nav";
import type { ReactNode } from "react";

export function Shell({ children }: { children: ReactNode }) {
  const path = usePathname();
  const desk = path.startsWith("/app");

  return (
    <div className="relative flex min-h-[100dvh] flex-col" style={{ zIndex: 1 }}>
      {desk ? <AppNav /> : <Nav />}
      <main className="min-w-0 flex-1">{children}</main>
      {desk ? (
        <footer className="border-t border-line">
          <div className="mx-auto flex max-w-[1400px] flex-col gap-1 px-4 pt-4 text-xs text-muted sm:flex-row sm:items-center sm:justify-between md:px-8 pb-[max(1rem,env(safe-area-inset-bottom,0px))]">
            <span>desk@code:~$</span>
            <span>awaiting genesis</span>
          </div>
        </footer>
      ) : (
        <Footer />
      )}
    </div>
  );
}
