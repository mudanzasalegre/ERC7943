"use client";

import * as React from "react";

/**
 * Returns true only after the component is mounted on the client.
 * Avoids hydration mismatches when wallet state differs between SSR
 * and the first client render.
 */
export function useMounted() {
  const [mounted, setMounted] = React.useState(false);
  React.useEffect(() => setMounted(true), []);
  return mounted;
}
