"use client";

import { useState } from "react";
import { XIcon } from "@phosphor-icons/react";

export function Connect() {
  const [open, setOpen] = useState(false);

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        className="min-h-10 border border-accent px-3 py-2 text-[11px] uppercase tracking-[0.14em] text-accent transition-[color,background-color,transform] duration-300 ease-[cubic-bezier(0.16,1,0.3,1)] hover:bg-accent hover:text-bg active:scale-[0.98] sm:px-4 sm:text-xs sm:tracking-[0.16em]"
      >
        Connect
      </button>
      {open ? (
        <div
          className="fixed inset-0 grid place-items-end bg-bg/80 px-4 py-4 sm:place-items-center sm:py-8"
          style={{ zIndex: 70, paddingBottom: "max(1rem, env(safe-area-inset-bottom, 0px))" }}
          role="dialog"
          aria-modal="true"
          aria-labelledby="connect-title"
          onClick={() => setOpen(false)}
        >
          <div
            className="w-full max-w-md border border-line bg-bg p-5 sm:p-6"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-start justify-between gap-4">
              <h2 id="connect-title" className="text-accent">
                $ connect
              </h2>
              <button
                type="button"
                aria-label="Close"
                onClick={() => setOpen(false)}
                className="grid size-11 shrink-0 place-items-center text-muted hover:text-fg"
              >
                <XIcon size={18} weight="bold" />
              </button>
            </div>
            <p className="mt-4 text-sm leading-relaxed text-muted">
              No registry on this network yet. The desk is wired. The chain is not.
            </p>
            <dl className="mt-6 grid gap-3 text-xs">
              <div className="flex justify-between gap-4">
                <dt className="shrink-0 text-muted">session</dt>
                <dd className="min-w-0 text-right">disconnected</dd>
              </div>
              <div className="flex justify-between gap-4">
                <dt className="shrink-0 text-muted">chain</dt>
                <dd className="min-w-0 text-right break-words">robinhood testnet 46630</dd>
              </div>
              <div className="flex justify-between gap-4">
                <dt className="shrink-0 text-muted">saine</dt>
                <dd className="min-w-0 text-right">undeployed</dd>
              </div>
            </dl>
          </div>
        </div>
      ) : null}
    </>
  );
}
