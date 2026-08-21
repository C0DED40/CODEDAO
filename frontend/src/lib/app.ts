export const APP_NAV = [
  { href: "/app/stake", label: "Stake CODE" },
  { href: "/app/proposals", label: "Proposals" },
] as const

export const DESK_STATS = [
  { key: "price", label: "CODE price", unit: "USD" },
  { key: "mcap", label: "Marketcap", unit: "USD" },
  { key: "tvl", label: "Staked", unit: "CODE" },
  { key: "treasury", label: "Treasury", unit: "WETH" },
  { key: "deployed", label: "Funds sent", unit: "WETH" },
  { key: "burned", label: "CODE burned", unit: "CODE" },
] as const

export const PROPOSAL_DESKS = [
  { href: "/app/proposals/pending", cmd: "pending", blurb: "Live votes and open SAINE rounds." },
  { href: "/app/proposals/closed", cmd: "closed", blurb: "Settled, lapsed, or halted." },
  { href: "/app/proposals/submit", cmd: "submit", blurb: "Guardian origination. Bond 1000 CODE." },
  { href: "/app/vintages", cmd: "vintages", blurb: "Season claims. Exit forfeits." },
] as const
