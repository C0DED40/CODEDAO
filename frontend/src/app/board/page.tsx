import type { Metadata } from "next";
import Image from "next/image";
import { Reveal } from "@/components/Reveal";
import { SeatList } from "@/components/SeatList";

export const metadata: Metadata = {
  title: "Board | CODE DAO",
};

export default function BoardPage() {
  return (
    <div className="mx-auto max-w-[1400px] px-4 py-12 md:px-8 md:py-24">
      <div className="grid gap-8 md:grid-cols-12 md:gap-12">
        <Reveal className="md:col-span-5">
          <h1 className="text-4xl tracking-tight text-accent md:text-6xl">SAINE</h1>
          <p className="mt-5 max-w-[48ch] text-sm leading-relaxed text-muted">
            Ten seats chosen for decorrelated failure. Not the ten strongest models. Ten different
            lineages, because ten copies of one reviewer is one reviewer.
          </p>
          <p className="mt-4 max-w-[48ch] text-sm leading-relaxed text-muted">
            Threshold 6 of 10. Liveness floor 8 of 10 reveals. Operator cap of two seats from phase
            two. Open weights capped at three.
          </p>
        </Reveal>
        <Reveal className="relative aspect-[16/10] overflow-hidden border border-line md:col-span-7 md:aspect-auto md:min-h-[280px]" delay={0.06}>
          <Image src="/board.png" alt="" fill className="object-cover opacity-80" />
        </Reveal>
      </div>

      <Reveal className="mt-12 min-w-0 md:mt-16">
        <SeatList />
      </Reveal>
    </div>
  );
}
