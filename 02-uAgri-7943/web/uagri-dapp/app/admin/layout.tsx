import type { ReactNode } from "react";
import AdminRouteGuard from "@/components/auth/AdminRouteGuard";

export default function AdminLayout({ children }: { children: ReactNode }) {
  return <AdminRouteGuard>{children}</AdminRouteGuard>;
}
