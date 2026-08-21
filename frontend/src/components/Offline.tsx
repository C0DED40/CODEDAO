import Link from "next/link";

export function Offline({
  title,
  body,
}: {
  title: string;
  body: string;
}) {
  return (
    <div className="border border-line bg-bg-raised p-5 md:p-12">
      <p className="text-accent">{`> ${title}`}</p>
      <p className="mt-4 max-w-[65ch] text-sm leading-relaxed text-muted">{body}</p>
      <Link
        href="/"
        className="mt-8 inline-flex min-h-12 w-full items-center justify-center border border-line px-4 py-2 text-xs uppercase tracking-[0.14em] text-fg hover:border-accent hover:text-accent sm:w-auto"
      >
        Return
      </Link>
    </div>
  );
}
