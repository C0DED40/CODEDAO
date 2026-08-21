"use client";

import { useState } from "react";

export function StakeDesk() {
  const [stake, setStake] = useState("");
  const [unstake, setUnstake] = useState("");

  return (
    <form
      className="border border-line bg-bg-raised p-6 md:p-8"
      onSubmit={(e) => e.preventDefault()}
    >
      <p className="text-accent">$ stake</p>

      <label className="mt-6 block text-xs uppercase tracking-[0.14em] text-muted" htmlFor="stake-amt">
        Stake CODE
      </label>
      <p className="mt-1 text-xs text-muted">Balance: 0</p>
      <input
        id="stake-amt"
        type="text"
        inputMode="decimal"
        autoComplete="off"
        value={stake}
        onChange={(e) => setStake(e.target.value)}
        className="mt-2 w-full border border-line bg-bg px-3 py-3 text-sm text-fg outline-none focus:border-accent"
      />
      <button
        type="button"
        disabled
        className="mt-3 w-full border border-line py-3 text-xs uppercase tracking-[0.14em] text-muted"
      >
        Approve
      </button>

      <label className="mt-8 block text-xs uppercase tracking-[0.14em] text-muted" htmlFor="unstake-amt">
        Withdraw DCODE
      </label>
      <p className="mt-1 text-xs text-muted">DCODE balance: 0</p>
      <div className="mt-2 flex gap-2">
        <input
          id="unstake-amt"
          type="text"
          inputMode="decimal"
          autoComplete="off"
          value={unstake}
          onChange={(e) => setUnstake(e.target.value)}
          className="min-w-0 flex-1 border border-line bg-bg px-3 py-3 text-sm text-fg outline-none focus:border-accent"
        />
        <button
          type="button"
          className="border border-line px-4 text-xs uppercase tracking-[0.12em] text-muted hover:text-accent"
          onClick={() => setUnstake("0")}
        >
          Max
        </button>
      </div>
      <button
        type="button"
        disabled
        className="mt-3 w-full border border-line py-3 text-xs uppercase tracking-[0.14em] text-muted"
      >
        Withdraw
      </button>

      <div className="mt-8 border-t border-line pt-6">
        <p className="text-xs uppercase tracking-[0.14em] text-muted">Claimable vintage</p>
        <p className="mt-2 text-sm">0 CODE</p>
        <button
          type="button"
          disabled
          className="mt-3 w-full border border-line py-3 text-xs uppercase tracking-[0.14em] text-muted"
        >
          Claim
        </button>
      </div>
    </form>
  );
}
