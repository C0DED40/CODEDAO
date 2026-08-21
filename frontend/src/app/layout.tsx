import type { Metadata, Viewport } from "next";
import { IBM_Plex_Mono, Oxanium } from "next/font/google";
import { MatrixRain } from "@/components/MatrixRain";
import { Scanlines } from "@/components/Scanlines";
import { Shell } from "@/components/Shell";
import "./globals.css";

const display = Oxanium({
  variable: "--font-oxanium",
  subsets: ["latin"],
  weight: ["500", "600", "700", "800"],
});

const mono = IBM_Plex_Mono({
  variable: "--font-ibm-plex-mono",
  subsets: ["latin"],
  weight: ["400", "500", "600", "700"],
});

export const metadata: Metadata = {
  title: "CODE DAO",
  description:
    "A decentralised venture organisation. Capital sits in an autonomous treasury. Ten agents read the code before a token moves.",
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
  themeColor: "#070907",
  colorScheme: "dark",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="en" className={`${display.variable} ${mono.variable} h-full antialiased`}>
      <body className={`${mono.className} min-h-full bg-bg text-fg`}>
        <MatrixRain />
        <Scanlines />
        <Shell>{children}</Shell>
      </body>
    </html>
  );
}
