import type { Metadata } from "next";
import { Back } from "@/components/Back";

export const metadata: Metadata = {
  title: "Vintages | CODE DAO",
};

export default function VintagesDesk() {
  return (
    <div className="mx-auto max-w-[800px] px-4 py-10 md:px-8 md:py-16">
      <Back href="/app/proposals" />
      <h1 className="mt-8 text-3xl tracking-tight text-accent">Vintages</h1>
      <p className="mt-4 max-w-[55ch] text-sm leading-relaxed text-muted">
        Each season keeps its own return stream. Claim in CODE. Leave before the boundary and the
        claim dies.
      </p>
      <p className="mt-8 border border-line px-5 py-8 text-sm text-muted">
        No vintages minted. This list fills when a deal returns.
      </p>
    </div>
  );
}
