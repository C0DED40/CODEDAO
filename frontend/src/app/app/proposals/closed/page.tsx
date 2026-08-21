import type { Metadata } from "next";
import { Back } from "@/components/Back";

export const metadata: Metadata = {
  title: "Closed | CODE DAO",
};

export default function ClosedPage() {
  return (
    <div className="mx-auto max-w-[800px] px-4 py-10 md:px-8 md:py-16">
      <Back href="/app/proposals" />
      <h1 className="mt-8 text-3xl tracking-tight text-accent">Closed proposals</h1>
      <p className="mt-8 border border-line px-5 py-8 text-sm text-muted">
        No closed proposals yet. Passed, lapsed, and halted originations will list here after the
        first season.
      </p>
    </div>
  );
}
