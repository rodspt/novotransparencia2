import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Novo Transparência",
  description: "Bases fundiárias e ambientais de propriedades rurais do Brasil",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="pt-BR">
      <body>{children}</body>
    </html>
  );
}
