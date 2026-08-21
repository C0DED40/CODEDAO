import Image from "next/image";
import { Cta } from "@/components/Cta";
import { Scramble } from "@/components/Scramble";

export function Hero({ ctaHref = "/app/stake" }: { ctaHref?: string }) {
  return (
    <section className="relative min-h-[100dvh] overflow-hidden">
      <Image src="/crt.png" alt="" fill priority className="object-cover object-[center_30%] opacity-35 md:object-center" />
      <div className="absolute inset-0 bg-bg/70" />
      <div className="relative mx-auto flex min-h-[calc(100dvh-var(--nav-offset))] max-w-[1400px] flex-col justify-center px-4 py-8 md:px-8 md:py-16">
        <h1 className="font-display font-extrabold leading-[0.86] tracking-[-0.05em] text-accent">
          <span className="block text-[clamp(3.5rem,24vw,6.5rem)] md:hidden">
            <Scramble text={"CODE.\nDAO"} className="whitespace-pre-line" />
            <span className="cursor-blink">_</span>
          </span>
          <span className="hidden text-[clamp(4.5rem,12vw,9rem)] md:inline">
            <Scramble text="CODE.DAO" />
            <span className="cursor-blink">_</span>
          </span>
        </h1>
        <p className="mt-6 max-w-[42ch] text-[0.95rem] leading-relaxed text-fg md:mt-8 md:text-lg">
          Capital sits in an autonomous treasury. Ten agents read the code before a token moves.
        </p>
        <div className="mt-8 md:mt-10">
          <Cta href={ctaHref} className="w-full justify-between sm:w-auto sm:justify-start">
            Stake CODE
          </Cta>
        </div>
      </div>
    </section>
  );
}
