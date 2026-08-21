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
        className="border border-accent px-4 py-2 text-xs uppercase tracking-[0.16em] text-accent transition-[color,background-color,transform] duration-300 ease-[cubic-bezier(0.16,1,0.3,1)] hover:bg-accent hover:text-bg active:scale-[0.98]"
      >
        Connect
      </button>
      {open ? (
        <div
          className="fixed inset-0 grid place-items-center bg-bg/80 px-4"
          style={{ zIndex: 60 }}
          role="dialog"
          aria-modal="true"
          aria-labelledby="connect-title"
          onClick={() => setOpen(false)}
        >
          <div
            className="w-full max-w-md border border-line bg-bg p-6"
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
                className="text-muted hover:text-fg"
              >
                <XIcon size={18} weight="bold" />
              </button>
            </div>
            <p className="mt-4 text-sm leading-relaxed text-muted">
              No registry on this network yet. The desk is wired. The chain is not.
            </p>
            <dl className="mt-6 grid gap-2 text-xs">
              <div className="flex justify-between gap-4">
                <dt className="text-muted">session</dt>
                <dd>disconnected</dd>
              </div>
              <div className="flex justify-between gap-4">
                <dt className="text-muted">chain</dt>
                <dd>robinhood testnet 46630</dd>
              </div>
              <div className="flex justify-between gap-4">
                <dt className="text-muted">saine</dt>
                <dd>undeployed</dd>
              </div>
            </dl>
          </div>
        </div>
      ) : null}
    </>
  );
}
