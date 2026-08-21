import Link from "next/link";
import { ArrowRightIcon } from "@phosphor-icons/react/ssr";

type Props = {
  href: string;
  children: string;
  variant?: "solid" | "ghost";
  className?: string;
};

export function Cta({ href, children, variant = "solid", className = "" }: Props) {
  const solid = variant === "solid";
  return (
    <Link
      href={href}
      className={`inline-flex min-h-12 items-center gap-3 border px-5 py-3 text-sm uppercase tracking-[0.14em] transition-[transform,background-color,color] duration-300 ease-[cubic-bezier(0.16,1,0.3,1)] active:scale-[0.98] ${
        solid
          ? "border-accent bg-accent text-bg hover:bg-transparent hover:text-accent"
          : "border-accent bg-transparent text-accent hover:bg-accent hover:text-bg"
      } ${className}`}
    >
      {children}
      <span className="grid size-7 shrink-0 place-items-center border border-current">
        <ArrowRightIcon size={14} weight="bold" />
      </span>
    </Link>
  );
}
