import type { Metadata, Viewport } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "NETA — ნახე. შეეხე. შეაკეთე.",
  description: "გადაუღე ფოტო იმას, რაც გაფუჭდა. კადრი ნაწილს პირდაპირ შენს ფოტოზე მონიშნავს და ნაბიჯ-ნაბიჯ გაგიძღვება — ქართულად.",
  openGraph: {
    title: "NETA — ნახე. შეეხე. შეაკეთე.",
    description: "ნაბიჯ-ნაბიჯ, შენს ფოტოზე.",
    locale: "ka_GE",
    type: "website",
  },
  icons: {
    icon: [
      { url: "/brand/favicon-32.png", sizes: "32x32", type: "image/png" },
      { url: "/brand/icon-192.png", sizes: "192x192", type: "image/png" },
    ],
    apple: [{ url: "/brand/apple-icon.png", sizes: "180x180", type: "image/png" }],
  },
  robots: { index: true, follow: true },
};

export const viewport: Viewport = { themeColor: "#020617", colorScheme: "light" };

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="ka">
      <body>
        <a href="#main-content" className="skip-link">მთავარ შიგთავსზე გადასვლა</a>
        {children}
      </body>
    </html>
  );
}
