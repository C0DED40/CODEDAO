import type { Metadata } from "next";
import { Hero } from "@/components/Hero";
import { Status } from "@/components/Status";

export const metadata: Metadata = {
  title: "Desk | CODE DAO",
};

export default function DeskPage() {
  return (
    <>
      <Hero />
      <Status />
    </>
  );
}
