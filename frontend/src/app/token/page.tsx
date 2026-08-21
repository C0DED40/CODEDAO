import type { Metadata } from "next";
import { Reveal } from "@/components/Reveal";

export const metadata: Metadata = {
  title: "Token economy | CODE DAO",
};

const GROUPS = [
  {
    title: "Supply",
    rows: [
      ["Total", "1,000,000,000 CODE"],
      ["Treasury", "50%"],
      ["Sale and LP", "40%"],
      ["Team", "6%"],
      ["Ops", "4%"],
    ],
  },
  {
    title: "Tax",
    rows: [
      ["Transfer tax", "0.49%"],
      ["To treasury", "0.40%"],
      ["To maintenance", "0.09%"],
    ],
  },
  {
    title: "Stake",
    rows: [
      ["Receipt", "DCODE"],
      ["Guardian seats", "50"],
      ["Season", "13 weeks"],
      ["Vintage claim", "stakers in that season"],
    ],
  },
  {
    title: "Deals",
    rows: [
      ["Cap", "0.5% of treasury TWAP"],
      ["Floor", "5 WETH"],
      ["Originations / season", "10"],
      ["Return split", "50% burn / 50% vintage"],
    ],
  },
];

export default function TokenPage() {
  return (
    <div className="mx-auto max-w-[1400px] px-4 py-12 md:px-8 md:py-24">
      <Reveal>
        <h1 className="text-3xl tracking-tight text-accent md:text-6xl">Token economy</h1>
        <p className="mt-4 max-w-[55ch] text-sm leading-relaxed text-muted">
          CODE is the unit. DCODE is the stake. Tax fills the treasury. Vintage is how returns come
          back to the people who sat the season.
        </p>
      </Reveal>

      <div className="mt-16 grid gap-10 md:grid-cols-2">
        {GROUPS.map((g, i) => (
          <Reveal key={g.title} delay={i * 0.05}>
            <h2 className="text-accent">{g.title}</h2>
            <dl className="mt-4 grid gap-3 text-sm">
              {g.rows.map(([k, v]) => (
                <div key={k} className="grid grid-cols-[1fr_auto] gap-4">
                  <dt className="text-muted">{k}</dt>
                  <dd className="min-w-0 text-right text-fg break-words">{v}</dd>
                </div>
              ))}
            </dl>
          </Reveal>
        ))}
      </div>
    </div>
  );
}
