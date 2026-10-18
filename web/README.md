# NETA landing

Next.js App Router + TypeScript + Tailwind CSS + Motion. Source design: `Camera/artboards/landing-v2.tsx` (read-only).

```sh
npm ci
npm run dev
npm run lint
npm run typecheck
npm run build
```

All code and assets live in `web/`. Georgian copy, local Inter/Noto Sans Georgian fonts and simulator screenshots follow the artboard. Primary CTA links open the GitHub repository; no beta signup or email collection. The demo video uses a thumbnail and only mounts a `youtube-nocookie.com` iframe after activation. Reduced motion removes spatial animations and the scan; opacity fades remain.

Production: https://neta-landing.vercel.app

Vercel project: `neta-landing`, scope: `bekas-projects-37aab3eb` (Beka's projects). Deploy from `web/` with `vercel --prod --scope bekas-projects-37aab3eb`. The uploaded project root is this directory; `vercel.json` selects Next.js, and `package.json` pins Node 22. No environment variables are required. `.vercel/` is ignored.

## Verification (2026-10-18)

- `npm run lint`, `npm run build`, `npm run typecheck`: passed.
- Browser panel `landing`: preview opened, video activated, and sticky story inspected at desktop/mobile widths.
- Production build checked with headless Chromium at 1200×900 and 375×900: no horizontal page overflow, all five story screens change, reel scrolls, video iframe is absent until clicked, and no browser errors (including reduced motion).
- axe WCAG 2/2.1 A/AA: zero violations in the page at both widths. YouTube's cross-origin player is excluded from that result; its own markup reports an `aria-prohibited-attr` issue. The iframe has a descriptive title.
- `npm audit --omit=dev`: zero vulnerabilities. Full audit reports five transitive development-tool findings through the ESLint/fast-glob/braces chain; its proposed fix downgrades Next's ESLint config, so it was not applied.
- Reference differences: NETA wordmark, GitHub CTA instead of beta signup, additional demo preview, and slightly darker small text/blue buttons for contrast. All other sections follow landing-v2.

Local-only screenshots and the detailed interaction report are under `.qa/` in the implementation checkout; this directory is intentionally ignored.

## Brand assets

`public/brand/neta-logo-original.png` and `app-icon-original.png` are unchanged copies of the iOS sources. The supplied wordmark already has alpha transparency. `neta-logo-light.svg` traces its original contours, changes dark letters to ink-50, and retains the sampled source blue (`#1b31fb`). Regenerate it with `python3 scripts/trace-logo.py` (Pillow and numpy required only for asset preparation). Header and footer use this transparent light variant through `next/image`.

The 32px favicon, 192px icon and 180px Apple touch icon are resized from the supplied AppIcon, not redrawn.
