import Link from "next/link";

export function Back({ href = "/app" }: { href?: string }) {
  return (
    <Link
      href={href}
      className="text-xs uppercase tracking-[0.16em] text-muted hover:text-accent"
    >
      Back
    </Link>
  );
}
