"use client";

import { useEffect, useRef } from "react";
import { useReducedMotion } from "motion/react";

const GLYPHS = "01アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホ0123456789";

export function MatrixRain() {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const reduce = useReducedMotion();

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || reduce) return;

    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    let frame = 0;
    let running = true;
    let cell = 16;
    let skip = 2;
    let cols = 0;
    let drops: number[] = [];

    const resize = () => {
      const mobile = window.innerWidth < 768;
      cell = mobile ? 22 : 16;
      skip = mobile ? 3 : 2;
      canvas.width = window.innerWidth;
      canvas.height = window.innerHeight;
      cols = Math.ceil(canvas.width / cell);
      drops = Array.from({ length: cols }, () => Math.random() * canvas.height);
    };

    const tick = () => {
      if (!running) return;
      frame += 1;
      if (!document.hidden && frame % skip === 0) {
        ctx.fillStyle = "rgba(7, 9, 7, 0.12)";
        ctx.fillRect(0, 0, canvas.width, canvas.height);
        ctx.font = `${cell}px ui-monospace, monospace`;
        for (let i = 0; i < drops.length; i += 1) {
          const ch = GLYPHS[Math.floor(Math.random() * GLYPHS.length)] ?? "0";
          ctx.fillStyle = i % 7 === 0 ? "#c8f0c8" : "#5eeb6a";
          ctx.fillText(ch, i * cell, drops[i]!);
          drops[i] = drops[i]! > canvas.height && Math.random() > 0.975 ? 0 : drops[i]! + cell;
        }
      }
      requestAnimationFrame(tick);
    };

    resize();
    window.addEventListener("resize", resize);
    const id = requestAnimationFrame(tick);

    return () => {
      running = false;
      cancelAnimationFrame(id);
      window.removeEventListener("resize", resize);
    };
  }, [reduce]);

  if (reduce) return null;

  return (
    <canvas
      ref={canvasRef}
      aria-hidden
      className="pointer-events-none fixed inset-0 opacity-[0.12]"
      style={{ zIndex: 0 }}
    />
  );
}
