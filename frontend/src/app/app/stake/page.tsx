import type { Metadata } from "next";
import { Back } from "@/components/Back";
import { StakeDesk } from "@/components/StakeDesk";

export const metadata: Metadata = {
  title: "Stake | CODE DAO",
};

const SIDE = [
  { label: "Guardian seats", value: "50" },
  { label: "Season", value: "13 weeks" },
  { label: "Total staked", value: "--" },
  { label: "CODE price", value: "--" },
];

export default function StakePage() {
  return (
    <div className="mx-auto max-w-[1400px] px-4 py-8 md:px-8 md:py-16">
      <Back />
      <div className="mt-8 grid items-start gap-8 lg:grid-cols-12">
        <aside className="grid grid-cols-2 gap-6 lg:col-span-3 lg:grid-cols-1">
          {SIDE.map((s) => (
            <div key={s.label}>
              <p className="text-xs uppercase tracking-[0.14em] text-muted">{s.label}</p>
              <p className="mt-2 text-lg text-fg">{s.value}</p>
            </div>
          ))}
        </aside>
        <div className="order-first lg:order-none lg:col-span-6">
          <StakeDesk />
        </div>
        <aside className="lg:col-span-3">
          <p className="text-xs uppercase tracking-[0.14em] text-muted">Seat</p>
          <p className="mt-2 text-sm leading-relaxed text-muted">
            Fifty largest DCODE balances are Guardians. Everyone else votes as the Many. Governance
            does not open until fifty seats are filled.
          </p>
        </aside>
      </div>
    </div>
  );
}
