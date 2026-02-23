import type { Metadata } from "next";
import "./globals.css";
import Providers from "@/components/providers/Providers";

// Required for nonce-based CSP: render per-request so Next can attach a nonce
// to its inlined scripts during render.
export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  title: "SkyBridge Compass Pro",
  description: "跨平台远程桌面与设备管理解决方案",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="zh-CN">
      <body className="antialiased">
        <Providers>
          {children}
        </Providers>
      </body>
    </html>
  );
}
