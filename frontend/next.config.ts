import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  async redirects() {
    return [
      { source: "/stake", destination: "/app/stake", permanent: false },
      { source: "/proposals", destination: "/app/proposals", permanent: false },
      { source: "/vintages", destination: "/app/vintages", permanent: false },
    ];
  },
};

export default nextConfig;
