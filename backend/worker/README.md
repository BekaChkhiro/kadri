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

## History

სესიების ისტორია (`src/history.ts`, სქემა `migrations/0001_init.sql`: `sessions`, `steps`, `feedback`, ON DELETE CASCADE).
ყველა endpoint-ს სჭირდება `Authorization: Bearer <session>` და მუშაობს მხოლოდ საკუთარ სესიებზე:
ტოკენის გარეშე → 401, სხვისი სესია → 403 `forbidden` („ამ სესიაზე წვდომა არ გაქვთ“), არარსებული → 404,
არასწორი body → 400 `invalid_request`.

| Endpoint | Body | პასუხი |
|---|---|---|
| `POST /sessions` | `{instructions, objectName?}` | 201 `{id, createdAt}` |
| `PUT /sessions/:id/keyframe` | `image/jpeg`, ≤ 2 MB (სხვა ტიპი → 415, დიდი → 413) | `{keyframeUrl}` |
| `GET /sessions/:id/keyframe` | — | `image/jpeg` R2-დან |
| `PATCH /sessions/:id` | `{status?, objectName?, parts?, costUsd?}` | `{id, updatedAt}` |
| `PUT /sessions/:id/steps` | `[{idx, title, text, focus[], avoid[]}]` (ყველას ცვლის) | `{id, stepCount, updatedAt}` |
| `POST /sessions/:id/feedback` | `{rating: 1–5, comment?}` | 201 `{id, createdAt}` |
| `GET /sessions?limit=20&cursor=` | — | `{sessions:[{id, objectName, status, createdAt, stepCount, keyframeUrl}], nextCursor}` |
| `GET /sessions/:id` | — | სრული: `parts`, `steps`, `feedback`, `costUsd`, `keyframeUrl`, … |
| `DELETE /sessions/:id` | — | 204; D1 ჩანაწერები და R2 ფოტო იშლება |

- `status`: `created | parts | steps | done | failed`.
- `parts`: `[{id, name, box:[x1,y1,x2,y2]}]`, კოორდინატები 0–1000, `x1≤x2`, `y1≤y2`, `id` უნიკალური (≤ 50 ცალი).
- R2 key: `users/<sub>/sessions/<id>/keyframe.jpg`. `keyframeUrl` აბსოლუტური URL-ია და იგივე Bearer token-ით იხსნება.
- სია ახლიდან ძველისკენაა (`created_at DESC, id DESC`), `limit` 1–50; შემდეგი გვერდისთვის `nextCursor` → `cursor`.
- Migration: `npx wrangler d1 migrations apply <db> --local|--remote --env <env>` (0000 და 0001 თანმიმდევრობით).

## Deploy

**Staging უკვე deploy-ებულია:** https://kadri-worker-staging.bekachkhirodze1.workers.dev
(D1 `kadri-staging`, R2 `kadri-photos-staging`, secret-ები `OPENAI_API_KEY`, `SESSION_SECRET`, `GOOGLE_CLIENT_IDS`).
სრული აღწერა, production-ის ნაბიჯები, secret-ების როტაცია და ლოგები — [`docs/DEPLOY.md`](../../docs/DEPLOY.md).

```sh
npx wrangler d1 migrations apply kadri-staging --env staging --remote   # ახალი migration-ის შემდეგ, deploy-მდე
npm run deploy:staging                                                  # wrangler deploy --env staging
node scripts/deploy_check.mjs https://kadri-worker-staging.bekachkhirodze1.workers.dev --env staging   # უფასო smoke
```

`deploy_check.mjs` ამოწმებს `/health` → 200 `{ok:true, env}`, `POST /ai/parts` და `GET /sessions` auth-ის გარეშე → 401 JSON.
Production (`kadri-worker-prod`) ჯერ არ შექმნილა — `wrangler.toml`-ში მისი `database_id` placeholder-ია.

Key-ები არასდროს git-ში — მხოლოდ `.dev.vars` (ლოკალურად) ან `wrangler secret`.

## AI ეტაპები (Astra C)

`src/routes/ai.ts` → `aiRoutes()` / `mountAiRoutes(router)`; ლოგიკა `src/ai/`-შია. პრომპტები და strict
სქემები `experiments/som-test/variant_c.py`-დან სიტყვასიტყვითაა გადმოტანილი (ჩაწერილ Python მოთხოვნებს
ბაიტ-ბაიტ ემთხვევა) — ტექსტი ახალი ექსპერიმენტის გარეშე არ შეცვალო. მოდელი `AI_MODEL` (default
`gpt-6-astra`), effort `AI_EFFORT` (default `low`; `minimal` არ მუშაობს). ფასიან მოთხოვნაზე retry არ ხდება.
`AI_PROVIDER=hybrid` ჯერ მხოლოდ ინტერფეისია და 501-ს აბრუნებს.

`src/index.ts` რთავს `mountGuardedAiRoutes`-ს: ორივე route-ს სჭირდება `Authorization: Bearer <session>` (401);
`/ai/parts` ამოწმებს დღიურ ლიმიტს (429 + `Retry-After`, router `LimitError`-ის headers-ს ატარებს), `AI_TIMEOUT_MS` → 504
`ai_timeout`, ყოველი ფასიანი ცდა (`ok|error|timeout`) `usage`-ში იწერება; `/ai/steps` — ლიმიტის გარეშე, timeout მთელ
stream-ზე (`event: error` `ai_timeout`), usage `ctx.waitUntil`-ით stream-ის ბოლოს. ორივე იღებს არასავალდებულო `sessionId`-ს.
`mountAiRoutes` (დაუცველი) მხოლოდ ტესტებისთვისაა.

- `POST /ai/parts` — multipart (`image` JPEG ფაილი + `instructions`) ან JSON `{image: base64, instructions}`;
  JPEG, დიდი გვერდი ≤768px, ≤2 MB. `instructions` — ტექსტი ან `[{title, text}]`. პასუხი:
  `{object, parts:[{id, name, box}], model, usage, costUsd, latencyMs}`; box 0–1000 XYXY, ID-ები სერვერზე
  `p1..pN` ცენტრის y-ით, შემდეგ x-ით; ≤12 ნაწილი. ცუდი box/სქემა → 502 `ai_invalid_response`.
- `POST /ai/steps` — JSON `{object, parts:[{id, name, box}], instructions, count?, image?}` → `text/event-stream`:
  `event: step` (`{index, title, text, focus, avoid, markers, arrows, tools, warn}`) თითო დასრულებულ ნაბიჯზე,
  მოდელი ჯერ კიდევ წერს; ბოლოს `event: done` (`{unknownParts, usage, costUsd, latencyMs, firstStepMs, model}`)
  ან `event: error` (`{code, message}`, ქართულად). ID-ები სქემაში მხოლოდ გადმოცემული `parts`-ის enum-ია.
  timeout 60 წმ. `image` არასავალდებულოა, მაგრამ ექსპერიმენტი ფოტოს მეორე ეტაპზეც აგზავნიდა.

ფასი: `src/ai/pricing.ts` (`vision.py` PRICES, 2026-10-17) — შეფასებაა, არა ინვოისი.

### ლაივ შემოწმება (ფასიანი)

```sh
rsync … # experiments/som-test/out_realism/c_astra_tracking/{sink,car,gym}/*/original/run_1/ მთავარი checkout-იდან
set -a; source ../../experiments/som-test/.env; set +a      # key-ს არ ბეჭდავს
node scripts/live_check.mjs --runs 3 --cap 3 --port 8797
```

სკრიპტი key-ს (და, თუ არ არის, შემთხვევით `SESSION_SECRET`-ს) `.dev.vars`-ში წერს, ლოკალურად უშვებს D1 migration-ებს და
`wrangler dev --local`-ს (`src/index.ts`), session token-ს `scripts/dev_token.mjs`-ით აწერს (ხელით:
`node scripts/dev_token.mjs --sub dev-user`; `--url`-ისთვის `--token`). ყოველ გამოძახებას
წინასწარ აჯავშნის `scripts/ledger.json`-ში და cap-ზე ჩერდება. შედეგები: `scripts/out/live_check.json`
(gitignored), ანგარიში — `docs/AI_LIVE_CHECK.md`.
