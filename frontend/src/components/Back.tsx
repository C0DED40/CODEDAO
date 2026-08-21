import Link from "next/link";

export function Back({ href = "/app" }: { href?: string }) {
  return (
    <Link
      href={href}
      className="inline-flex min-h-11 items-center text-xs uppercase tracking-[0.16em] text-muted hover:text-accent"
    >
      Back
    </Link>
  );
}
