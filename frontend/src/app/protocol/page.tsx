import type { Metadata } from "next";
import { Reveal } from "@/components/Reveal";
import { Cta } from "@/components/Cta";

export const metadata: Metadata = {
  title: "Protocol | CODE DAO",
};

const STEPS = [
  {
    cmd: "guardian.submit",
    body: "A seated Guardian posts an origination. Bond is 1000 liquid CODE. Two originations per Guardian per season.",
  },
  {
    cmd: "many.vote",
    body: "Five days. Quorum is 10% of seasonal effective power. Wrong vote costs 10%. Silence costs 15%.",
  },
  {
    cmd: "saine.round",
    body: "Commit 24h, reveal 24h. Six of ten must approve. Eight must reveal or the round lapses.",
  },
  {
    cmd: "timelock.execute",
    body: "Twenty-four hours after a pass. Then Escrow registers the deal. Tranches: 40 / 30 / 30.",
  },
];

export default function ProtocolPage() {
  return (
    <div className="mx-auto max-w-[900px] px-4 py-16 md:px-8 md:py-24">
      <Reveal>
        <h1 className="text-4xl tracking-tight text-accent md:text-6xl">Protocol</h1>
        <p className="mt-4 max-w-[55ch] text-sm leading-relaxed text-muted">
          Money does not move on a vote. It moves after the board, after the delay, into an escrow
          that can halt.
        </p>
      </Reveal>

      <ol className="mt-16 space-y-12">
        {STEPS.map((s, i) => (
          <Reveal key={s.cmd} delay={i * 0.04}>
            <li>
              <p className="text-accent">{`$ ${s.cmd}`}</p>
              <p className="mt-3 max-w-[60ch] text-sm leading-relaxed text-fg">{s.body}</p>
            </li>
          </Reveal>
        ))}
      </ol>

      <Reveal className="mt-16">
        <Cta href="/app/proposals" variant="ghost">
          Proposals
        </Cta>
      </Reveal>
    </div>
  );
}
