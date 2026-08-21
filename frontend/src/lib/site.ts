export const NAV = [
  { href: "/", label: "Home" },
  { href: "/token", label: "Token" },
  { href: "/protocol", label: "Protocol" },
  { href: "/board", label: "Board" },
  { href: "/manifesto", label: "Manifesto" },
] as const

export const SEATS = [
  { slot: 0, provider: "Anthropic", model: "claude-opus-5" },
  { slot: 1, provider: "OpenAI", model: "gpt-5.6-sol" },
  { slot: 2, provider: "Google", model: "gemini-3.7-flash" },
  { slot: 3, provider: "xAI", model: "grok-4.6" },
  { slot: 4, provider: "Mistral", model: "mistral-medium-3-5" },
  { slot: 5, provider: "Meta", model: "muse-spark-1.2" },
  { slot: 6, provider: "DeepSeek", model: "deepseek-v4-pro" },
  { slot: 7, provider: "Alibaba", model: "qwen3.8-max" },
  { slot: 8, provider: "Z.ai", model: "glm-5.3" },
  { slot: 9, provider: "Moonshot", model: "kimi-k3" },
] as const
