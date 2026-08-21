import Image from "next/image";
import { Cta } from "@/components/Cta";
import { Scramble } from "@/components/Scramble";

export function Hero({ ctaHref = "/app/stake" }: { ctaHref?: string }) {
  return (
    <section className="relative min-h-[100dvh] overflow-hidden">
      <Image src="/crt.png" alt="" fill priority className="object-cover opacity-35" />
      <div className="absolute inset-0 bg-bg/70" />
      <div className="relative mx-auto flex min-h-[100dvh] max-w-[1400px] flex-col justify-center px-4 pt-16 pb-16 md:px-8">
        <h1 className="font-display max-w-5xl text-6xl leading-[0.92] font-extrabold tracking-[-0.04em] text-accent sm:text-7xl md:text-8xl lg:text-[9rem]">
          <Scramble text="CODE.DAO" />
          <span className="cursor-blink">_</span>
        </h1>
        <p className="mt-8 max-w-[42ch] text-base leading-relaxed text-fg md:text-lg">
          Capital sits in an autonomous treasury. Ten agents read the code before a token moves.
        </p>
        <div className="mt-10">
          <Cta href={ctaHref}>Stake CODE</Cta>
        </div>
      </div>
    </section>
  );
}
