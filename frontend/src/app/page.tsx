import Image from "next/image";
import { Hero } from "@/components/Hero";
import { Reveal } from "@/components/Reveal";
import { Status } from "@/components/Status";
import { SEATS } from "@/lib/site";

export default function Home() {
  return (
    <>
      <Hero />
      <Status />

      <section className="border-t border-line">
        <div className="mx-auto max-w-[1400px] px-4 py-24 md:px-8 md:py-32">
          <Reveal>
            <pre className="overflow-x-auto text-sm leading-8 text-fg md:text-base">
              {`$ origin
  50 guardians submit deals. Two per season. Bond: 1000 CODE.

$ suffrage
  Everyone else votes. Quorum is 10% of seasonal power. Five days.

$ adjudicate
  Ten models. Six must approve. Eight must reveal. Then the timelock.

$ execute
  WETH leaves the treasury. Not before.`}
            </pre>
          </Reveal>
        </div>
      </section>

      <section className="relative min-h-[100dvh] overflow-hidden border-t border-line">
        <Image src="/board.png" alt="" fill className="object-cover opacity-30" />
        <div className="absolute inset-0 bg-bg/75" />
        <div className="relative mx-auto grid min-h-[100dvh] max-w-[1400px] items-center gap-12 px-4 py-24 md:grid-cols-12 md:px-8">
          <Reveal className="md:col-span-5">
            <h2 className="text-3xl tracking-tight text-fg md:text-5xl">
              The board reads the code
            </h2>
            <p className="mt-5 max-w-[52ch] text-sm leading-relaxed text-muted">
              SAINE is ten seats, ten providers, six of ten to pass. CULT had a vote. CODE puts a
              model board between the vote and the money.
            </p>
          </Reveal>
          <Reveal className="md:col-span-7" delay={0.08}>
            <ol className="grid grid-cols-1 gap-x-8 gap-y-3 sm:grid-cols-2">
              {SEATS.map((s) => (
                <li key={s.slot} className="flex gap-3 text-sm text-fg">
                  <span className="w-6 text-accent">{String(s.slot).padStart(2, "0")}</span>
                  <span className="text-muted">{s.provider}</span>
                  <span className="ml-auto font-normal text-fg">{s.model}</span>
                </li>
              ))}
            </ol>
          </Reveal>
        </div>
      </section>

      <section className="border-t border-line">
        <div className="mx-auto grid max-w-[1400px] gap-12 px-4 py-24 md:grid-cols-2 md:px-8 md:py-32">
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
