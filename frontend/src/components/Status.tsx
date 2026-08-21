import Image from "next/image";
import { DESK_STATS } from "@/lib/app";

export function Status() {
  return (
    <section id="status" className="border-t border-line">
      <div className="mx-auto grid max-w-[1400px] gap-10 px-4 py-16 md:grid-cols-12 md:px-8 md:py-24">
        <div className="md:col-span-7">
          <p className="font-display text-xl tracking-tight text-accent md:text-2xl">$ status</p>
          <p className="mt-2 text-xs text-muted">rpc offline. values are empty until genesis.</p>
          <dl className="mt-8">
            {DESK_STATS.map((row) => (
              <div
                key={row.key}
                className="grid grid-cols-[1fr_auto_auto] items-baseline gap-4 border-b border-line/60 py-3 text-sm last:border-b-0"
              >
                <dt className="text-muted">{row.label}</dt>
                <dd className="text-fg">--</dd>
                <dd className="w-12 text-right text-xs text-muted">{row.unit}</dd>
              </div>
            ))}
          </dl>
        </div>
        <div className="relative min-h-[280px] border border-line md:col-span-5">
          <Image src="/vault.png" alt="Vault door with a green lamp" fill className="object-cover opacity-70" />
        </div>
      </div>
    </section>
  );
}
