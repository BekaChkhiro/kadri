"use client";

import { useSyncExternalStore } from "react";

const query = "(prefers-reduced-motion: reduce)";
function subscribe(onChange: () => void) {
  const media = window.matchMedia(query);
  media.addEventListener("change", onChange);
  return () => media.removeEventListener("change", onChange);
}
const getSnapshot = () => window.matchMedia(query).matches;
const getServerSnapshot = () => false;

// Keep the first client render identical to SSR. The CSS media query suppresses
// spatial motion immediately, including before React hydrates.
export function useReducedMotion() {
  return useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);
}
