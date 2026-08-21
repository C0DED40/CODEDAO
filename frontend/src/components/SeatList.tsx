import { SEATS } from "@/lib/site";

export function SeatList() {
  return (
    <ol className="grid grid-cols-1 gap-x-8 gap-y-4 sm:grid-cols-2">
      {SEATS.map((s) => (
        <li
          key={s.slot}
          className="grid grid-cols-[1.75rem_minmax(0,1fr)] gap-x-3 text-sm sm:grid-cols-[1.75rem_minmax(0,1fr)_auto]"
        >
          <span className="text-accent">{String(s.slot).padStart(2, "0")}</span>
          <span className="min-w-0 text-muted">{s.provider}</span>
          <span className="col-start-2 min-w-0 break-all text-fg sm:col-start-3">{s.model}</span>
        </li>
      ))}
    </ol>
  );
}
