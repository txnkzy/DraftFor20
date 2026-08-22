import type { MetadataRoute } from "next";
import { SITE_URL } from "@/lib/site";

export default function robots(): MetadataRoute.Robots {
  return {
    rules: {
      userAgent: "*",
      allow: "/",
      // rooms and results carry player-entered names and are unlisted by design
      disallow: ["/room/", "/results/", "/host", "/api/"],
    },
    sitemap: `${SITE_URL}/sitemap.xml`,
  };
}
