import type { Metadata } from "next";
import { Back } from "@/components/Back";

export const metadata: Metadata = {
  title: "Submit | CODE DAO",
};

export default function SubmitPage() {
  return (
    <div className="mx-auto max-w-[640px] px-4 py-10 md:px-8 md:py-16">
      <Back href="/app/proposals" />
      <h1 className="mt-8 text-3xl tracking-tight text-accent">Submit proposal</h1>
      <p className="mt-3 text-sm text-muted">Guardians only. Bond 1000 liquid CODE.</p>
      <form className="mt-10 space-y-6">
        <div className="flex flex-col gap-2">
          <label htmlFor="investee" className="text-xs uppercase tracking-[0.14em] text-muted">
            Investee
          </label>
          <input
            id="investee"
            name="investee"
            disabled
            className="border border-line bg-bg px-3 py-3 text-sm text-muted"
          />
        </div>
        <div className="flex flex-col gap-2">
          <label htmlFor="amount" className="text-xs uppercase tracking-[0.14em] text-muted">
            Draw (WETH)
          </label>
          <input
            id="amount"
            name="amount"
            disabled
            className="border border-line bg-bg px-3 py-3 text-sm text-muted"
          />
        </div>
        <div className="flex flex-col gap-2">
          <label htmlFor="manifest" className="text-xs uppercase tracking-[0.14em] text-muted">
            Manifest CID
          </label>
          <input
            id="manifest"
            name="manifest"
            disabled
            className="border border-line bg-bg px-3 py-3 text-sm text-muted"
          />
        </div>
        <button
          type="submit"
          disabled
          className="w-full border border-line py-3 text-xs uppercase tracking-[0.14em] text-muted"
        >
          Submit
        </button>
      </form>
    </div>
  );
}
