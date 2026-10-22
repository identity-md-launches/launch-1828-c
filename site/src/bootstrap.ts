import "@fontsource/barlow-condensed/latin-600.css";
import "@fontsource/ibm-plex-mono/latin-400.css";

// Paint the real, unpriced static shell first, then hydrate it and read Sepolia.
// This is a render boundary, not a timer or a network-dependent splash screen.
if (!location.hash || location.hash === "#/") {
  if ("PerformanceObserver" in window && PerformanceObserver.supportedEntryTypes?.includes("paint")) {
    const painted = new PerformanceObserver((list) => {
      if (!list.getEntries().some((entry) => entry.name === "first-contentful-paint")) return;
      painted.disconnect();
      void import("./main");
    });
    painted.observe({ type: "paint", buffered: true });
  } else {
    requestAnimationFrame(() => requestAnimationFrame(() => { void import("./main"); }));
  }
} else {
  void import("./main");
}
