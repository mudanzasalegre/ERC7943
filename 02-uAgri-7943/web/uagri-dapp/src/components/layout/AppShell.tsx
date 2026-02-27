"use client";

import * as React from "react";
import Header from "./Header";
import BottomNav from "./BottomNav";
import Container from "./Container";
import WalletStatusBanner from "@/components/wallet/WalletStatusBanner";
import CriticalStatusBanner from "@/components/wallet/CriticalStatusBanner";

export default function AppShell({ children }: { children: React.ReactNode }) {
  return (
    <div className="min-h-screen">
      <Header />
      <WalletStatusBanner />
      <CriticalStatusBanner />
      <main className="pb-24 pt-2 md:pb-10 md:pt-3">
        <Container>{children}</Container>
      </main>
      <BottomNav />
    </div>
  );
}
