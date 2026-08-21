"use client";

import { useEffect, useState } from "react";
import { useReducedMotion } from "motion/react";

const POOL = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

export function Scramble({ text, className }: { text: string; className?: string }) {
  const reduce = useReducedMotion();
  const [out, setOut] = useState(reduce ? text : text.replace(/[A-Za-z0-9]/g, "0"));

  useEffect(() => {
    if (reduce) {
      setOut(text);
      return;
    }
    let i = 0;
    const id = window.setInterval(() => {
      i += 1;
      const revealed = Math.floor((i / 18) * text.length);
      setOut(
        text
          .split("")
          .map((ch, idx) => {
            if (idx < revealed || ch === " " || ch === ".") return ch;
            return POOL[Math.floor(Math.random() * POOL.length)] ?? ch;
          })
          .join(""),
      );
      if (revealed >= text.length) window.clearInterval(id);
    }, 40);
    return () => window.clearInterval(id);
  }, [reduce, text]);

  return <span className={className}>{out}</span>;
}
