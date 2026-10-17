# kadri-worker

Cloudflare Worker — „კადრი“-ს API. TypeScript, wrangler 4, vitest + `@cloudflare/vitest-plugin`.

**Node 22+ სჭირდება** (wrangler 4.151 Node 20-ზე არ ეშვება; `.nvmrc` = 22). Homebrew-ზე:
`export PATH=/opt/homebrew/opt/node@22/bin:$PATH`.

## ლოკალურად

```sh
npm ci
cp .dev.vars.example .dev.vars   # საჭიროების შემთხვევაში ჩაწერე key-ები; ფაილი gitignored-ია
npm run dev                      # wrangler dev → http://localhost:8787 (D1/R2 ლოკალურად, Miniflare)
curl localhost:8787/health
```

## შემოწმება

```sh
npm run typecheck
npm test
```

ტესტები Workers runtime-ში ეშვება (`vitest.config.ts` კითხულობს `wrangler.toml`-ს).

> `npm install`-ით ახალი პაკეტის დამატებისას npm 10 ზოგჯერ `Cannot read properties of null (reading 'edgesOut')`
> შეცდომას აგდებს (arborist bug vitest-ის optional peer-ებზე). გამოსავალი: `npx -y npm@11 install -D <pkg>`.
> `npm ci` lockfile-იდან ჩვეულებრივ მუშაობს.

## Auth

iOS აპი Google Sign-In-ით იღებს **Google ID token**-ს და აგზავნის Worker-ზე; Worker ამოწმებს და აძლევს საკუთარ,
1-საათიან session JWT-ს (HS256, `SESSION_SECRET`).

| Endpoint | Body / Header | პასუხი |
|---|---|---|
| `POST /auth/google` | `{"idToken": "<Google ID token>"}` | `{sessionToken, expiresAt, user:{id,email,name,picture}}` |
| `POST /auth/refresh` | `Authorization: Bearer <session>` (ჯერ ვალიდური) | `{sessionToken, expiresAt}` |
| `GET /me` | `Authorization: Bearer <session>` | `{user}` — დაცული endpoint-ის ნიმუში |

ID token-ის შემოწმება (`src/auth.ts`): Google JWKS (`https://www.googleapis.com/oauth2/v3/certs`, cache `max-age`-ის
მიხედვით), RS256 ხელმოწერა, `iss` = `accounts.google.com` / `https://accounts.google.com`, `aud` ∈ `GOOGLE_CLIENT_IDS`,
`exp`/`iat` (±60 წმ), `email_verified`. მომხმარებელი იწერება D1 `users` ცხრილში (`migrations/0000_users.sql`, `id` = Google `sub`).
ნებისმიერი შეცდომა → `401 {"error":{"code":"unauthorized","message":"ავტორიზაცია საჭიროა"}}`.

სხვა route-ის დასაცავად: `const { sub, email } = await requireSession(request, env);` (`src/session.ts`, ასევე
ექსპორტირებულია `src/index.ts`-დან).

### Google OAuth client ID-ების მოპოვება (ადამიანმა)

1. [Google Cloud Console](https://console.cloud.google.com/) → პროექტი → **APIs & Services → OAuth consent screen** —
   შეავსე (External, აპის სახელი „კადრი“, scope-ები `openid email profile`).
2. **APIs & Services → Credentials → Create credentials → OAuth client ID**:
   - **iOS** ტიპი, Bundle ID `ge.kadri.app` → მიიღებ iOS client ID-ს (და reversed client ID-ს URL scheme-ისთვის iOS აპში).
   - **Web application** ტიპი (redirect URI არ სჭირდება) → Web client ID. iOS-ზე `serverClientID`-ად ის გამოიყენება,
     რომ token-ის `aud` Web client ID იყოს.
3. ორივე ID ჩაწერე მძიმით: `GOOGLE_CLIENT_IDS=<ios-id>.apps.googleusercontent.com,<web-id>.apps.googleusercontent.com`.

### Secret-ები

```sh
openssl rand -base64 48                                  # SESSION_SECRET-ის გენერაცია
npx wrangler secret put SESSION_SECRET --env staging     # ჩასვი გენერირებული მნიშვნელობა
npx wrangler secret put GOOGLE_CLIENT_IDS --env staging  # <ios-id>,<web-id>
npx wrangler d1 migrations apply kadri-staging --remote --env staging
```

production-ისთვის იგივე `--env production`-ით (`kadri-prod`) — სხვა `SESSION_SECRET`-ით. ლოკალურად ორივე ცვლადი
`.dev.vars`-ში ჩაწერე და `npx wrangler d1 migrations apply kadri-dev --local`. ტესტებს ნამდვილი Google client
არ სჭირდება — ID token-ს ტესტი საკუთარი RSA key-ით აწერს ხელს და JWKS fetch stub-ით მოდის.

## Limits

`src/limits.ts` — დამოუკიდებელი მოდული AI route-ებისთვის; ჩანაწერები D1 `usage` ცხრილშია (`migrations/0002_usage.sql`).

| ფუნქცია | რას აკეთებს |
|---|---|
| `assertDailyLimit(env, userId)` | დღევანდელი (UTC) `stage='parts'` ჩანაწერები ≥ `DAILY_SESSION_LIMIT` → `429 daily_limit` („დღევანდელი ლიმიტი ამოიწურა, სცადეთ ხვალ“), `Retry-After` = წამები UTC შუაღამემდე |
| `recordUsage(env, row)` | ერთი AI მოთხოვნის ჩაწერა (ტოკენები, `cost_usd`, `latency_ms`, `status` ok\|error\|timeout); ფასს გამომძახებელი ითვლის |
| `withTimeout(ms, signal => …)` | `AbortController`; ვადის გასვლისას signal abort-დება და `504 ai_timeout` („პასუხი დროში ვერ მოვიდა, სცადეთ თავიდან“) |
| `usageSummary(env, userId, days = 30)` | `{days, sessions, costUsd}` პარამეტრების ეკრანისთვის |

ცვლადები (`wrangler.toml` `[vars]`, სამივე გარემოში): `DAILY_SESSION_LIMIT` (default `20`), `AI_TIMEOUT_MS` (default `60000`).
სესიად ითვლება ყოველი `parts` ჩანაწერი, მათ შორის `error`/`timeout` — ფასიანი მოთხოვნა მაინც დაიხარჯა.

> **⚠️ ფასიან AI მოთხოვნაზე retry არ ხდება — არც `withTimeout`-ში, არც სერვერზე სხვაგან.** Timeout-ის ან შეცდომის
> შემდეგ კლიენტი (მომხმარებელი) წყვეტს, სცადოს თუ არა თავიდან; ყოველი ცდა ცალკე ჩაიწერება `usage`-ში.

`assertDailyLimit` აგდებს `LimitError`-ს (`ApiError` + `headers`); `Retry-After` პასუხამდე რომ მივიდეს, router-მა
`errorResponse(err, err.headers)` უნდა გამოიძახოს `LimitError`-ისთვის.

## Deploy (ადამიანმა უნდა გააკეთოს)

1. `npx wrangler login`
2. D1 და R2 შექმნა — ზუსტი ბრძანებები `wrangler.toml`-ის თავშია; დაბეჭდილი `database_id`-ები ჩასვი
   `TODO-set-after-wrangler-d1-create`-ის ნაცვლად.
3. Secret-ები თითო გარემოზე: `npx wrangler secret put OPENAI_API_KEY --env staging`
   (ასევე `GEMINI_API_KEY`, `SESSION_SECRET`, `GOOGLE_CLIENT_IDS`; production-ისთვის `--env production`).
4. `npm run deploy:staging` / `npm run deploy:prod`.

Key-ები არასდროს git-ში — მხოლოდ `.dev.vars` (ლოკალურად) ან `wrangler secret`.
