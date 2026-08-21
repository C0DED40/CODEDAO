import type { Metadata } from "next";
import { Reveal } from "@/components/Reveal";

export const metadata: Metadata = {
  title: "Manifesto | CODE DAO",
};

const LINES = [
  {
    head: "The treasury is not a committee",
    body: "Capital sits on-chain. Draws price themselves. No signer set can empty it because a vote felt urgent.",
  },
  {
    head: "Deal flow is not open mic",
    body: "The fifty largest stakers originate. Two proposals each per season. Everyone else votes. That split is load-bearing.",
  },
  {
    head: "A vote is not a wire",
    body: "Between yes and WETH there is a board of ten independent models that has to read the code, commit, and reveal. Six to pass. Eight to live.",
  },
  {
    head: "Returns come back as vintage",
    body: "Half of what comes home is burned. Half accrues to the season that funded the deal. Exit early and you forfeit the claim.",
  },
];

export default function ManifestoPage() {
  return (
    <div className="mx-auto max-w-[800px] px-4 py-12 md:px-8 md:py-24">
      <Reveal>
        <h1 className="text-3xl tracking-tight text-accent md:text-6xl">Manifesto</h1>
      </Reveal>
      <div className="mt-16 space-y-16">
        {LINES.map((line, i) => (
          <Reveal key={line.head} delay={i * 0.05}>
            <h2 className="text-2xl tracking-tight text-fg md:text-3xl">{line.head}</h2>
            <p className="mt-4 max-w-[60ch] text-sm leading-relaxed text-muted">{line.body}</p>
          </Reveal>
        ))}
      </div>
    </div>
  );
}
