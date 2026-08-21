export function Scanlines() {
  return (
    <div
      aria-hidden
      className="pointer-events-none fixed inset-0 opacity-40"
      style={{
        zIndex: 40,
        backgroundImage:
          "repeating-linear-gradient(to bottom, transparent 0, transparent 2px, rgba(0, 0, 0, 0.18) 3px)",
        mixBlendMode: "multiply",
      }}
    />
  );
}
