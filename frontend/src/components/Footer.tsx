export function Footer() {
  return (
    <footer className="relative border-t border-line" style={{ zIndex: 1 }}>
      <div className="mx-auto flex max-w-[1400px] flex-col gap-6 px-4 py-10 pb-[max(2.5rem,env(safe-area-inset-bottom,0px))] md:flex-row md:items-end md:justify-between md:px-8">
        <p className="text-xs uppercase tracking-[0.16em] text-muted">
          code@dao:~$
          <span className="cursor-blink ml-2 text-accent">_</span>
        </p>
        <p className="max-w-sm text-xs leading-relaxed text-muted/80">
          Nothing here is an offer of securities or a solicitation of investment.
        </p>
      </div>
    </footer>
  );
}
