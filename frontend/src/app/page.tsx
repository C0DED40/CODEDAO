import Image from "next/image";
import { Hero } from "@/components/Hero";
import { Reveal } from "@/components/Reveal";
import { SeatList } from "@/components/SeatList";
import { Status } from "@/components/Status";

const PIPE = [
  ["origin", "50 guardians submit deals. Two per season. Bond: 1000 CODE."],
  ["suffrage", "Everyone else votes. Quorum is 10% of seasonal power. Five days."],
  ["adjudicate", "Ten models. Six must approve. Eight must reveal. Then the timelock."],
  ["execute", "WETH leaves the treasury. Not before."],
] as const;

export default function Home() {
  return (
    <>
      <Hero />
      <Status />

      <section className="border-t border-line">
        <div className="mx-auto max-w-[1400px] px-4 py-12 md:px-8 md:py-32">
          <Reveal>
            <dl className="grid gap-8 text-sm leading-7 text-fg md:text-base md:leading-8">
              {PIPE.map(([cmd, body]) => (
                <div key={cmd}>
                  <dt className="text-accent">{`$ ${cmd}`}</dt>
                  <dd className="mt-2 max-w-[60ch] text-fg">{body}</dd>
                </div>
              ))}
            </dl>
          </Reveal>
        </div>
      </section>

      <section className="relative overflow-hidden border-t border-line md:min-h-[100dvh]">
        <Image src="/board.png" alt="" fill className="object-cover opacity-30" />
        <div className="absolute inset-0 bg-bg/75" />
        <div className="relative mx-auto grid max-w-[1400px] items-center gap-10 px-4 py-12 md:min-h-[100dvh] md:grid-cols-12 md:gap-12 md:px-8 md:py-24">
          <Reveal className="md:col-span-5">
            <h2 className="text-3xl tracking-tight text-fg md:text-5xl">
              The board reads the code
            </h2>
            <p className="mt-5 max-w-[52ch] text-sm leading-relaxed text-muted">
              SAINE is ten seats, ten providers, six of ten to pass. CULT had a vote. CODE puts a
              model board between the vote and the money.
            </p>
          </Reveal>
          <Reveal className="min-w-0 md:col-span-7" delay={0.08}>
            <SeatList />
          </Reveal>
        </div>
      </section>

      <section className="border-t border-line">
        <div className="mx-auto grid max-w-[1400px] gap-8 px-4 py-12 md:grid-cols-2 md:gap-12 md:px-8 md:py-32">
          <Reveal>
            <div className="relative aspect-[4/3] overflow-hidden border border-line">
              <Image src="/vault.png" alt="Vault door with a single green lamp" fill className="object-cover" />
            </div>
          </Reveal>
          <Reveal delay={0.06} className="flex flex-col justify-center">
            <h2 className="text-3xl tracking-tight md:text-4xl">Treasury that cannot be rushed</h2>
            <p className="mt-5 max-w-[52ch] text-sm leading-relaxed text-muted">
              0.49% tax on every transfer. 0.40 to the treasury, 0.09 to maintenance. Draws price
              against a v2 TWAP. Per deal: 0.5% of the chest, never below 5 WETH.
            </p>
            <p className="mt-4 max-w-[52ch] text-sm leading-relaxed text-muted">
              Returns split 50% burn, 50% vintage. Stakers claim from the vintage they sat through.
            </p>
          </Reveal>
        </div>
      </section>
    </>
  );
}
