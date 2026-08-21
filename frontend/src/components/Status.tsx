import Image from "next/image";
import { DESK_STATS } from "@/lib/app";

export function Status() {
  return (
    <section id="status" className="border-t border-line">
      <div className="mx-auto grid max-w-[1400px] gap-8 px-4 py-12 md:grid-cols-12 md:gap-10 md:px-8 md:py-24">
        <div className="min-w-0 md:col-span-7">
          <p className="font-display text-xl tracking-tight text-accent md:text-2xl">$ status</p>
          <p className="mt-2 text-xs text-muted">rpc offline. values are empty until genesis.</p>
          <dl className="mt-6 md:mt-8">
            {DESK_STATS.map((row) => (
              <div
                key={row.key}
                className="grid grid-cols-[minmax(0,1fr)_auto_auto] items-baseline gap-x-3 gap-y-1 border-b border-line/60 py-3 text-sm last:border-b-0 sm:gap-4"
              >
                <dt className="min-w-0 text-muted">{row.label}</dt>
                <dd className="text-fg">--</dd>
                <dd className="w-10 text-right text-[11px] text-muted sm:w-12 sm:text-xs">{row.unit}</dd>
              </div>
            ))}
          </dl>
        </div>
        <div className="relative aspect-[16/10] overflow-hidden border border-line md:col-span-5 md:aspect-auto md:min-h-[280px]">
          <Image src="/vault.png" alt="Vault door with a green lamp" fill className="object-cover opacity-70" />
        </div>
      </div>
    </section>
  );
}
