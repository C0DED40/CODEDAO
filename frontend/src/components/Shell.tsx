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
      <main className="flex-1">{children}</main>
      {desk ? (
        <footer className="border-t border-line">
          <div className="mx-auto flex max-w-[1400px] items-center justify-between px-4 py-4 text-xs text-muted md:px-8">
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
