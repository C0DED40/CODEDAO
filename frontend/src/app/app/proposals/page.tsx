import type { Metadata } from "next";
import Link from "next/link";
import { Back } from "@/components/Back";
import { PROPOSAL_DESKS } from "@/lib/app";

export const metadata: Metadata = {
  title: "Proposals | CODE DAO",
};

export default function ProposalsHub() {
  return (
    <div className="mx-auto max-w-[800px] px-4 py-10 md:px-8 md:py-16">
      <Back />
      <h1 className="mt-8 text-3xl tracking-tight text-accent md:text-4xl">$ proposals</h1>
      <ul className="mt-12">
        {PROPOSAL_DESKS.map((d) => (
          <li key={d.href}>
            <Link
              href={d.href}
              className="group flex flex-col gap-1 py-5 sm:flex-row sm:items-baseline sm:justify-between"
            >
              <span className="text-fg group-hover:text-accent">{d.cmd}/</span>
              <span className="text-sm text-muted">{d.blurb}</span>
            </Link>
          </li>
        ))}
      </ul>
    </div>
  );
}
