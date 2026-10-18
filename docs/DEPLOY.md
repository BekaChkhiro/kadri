# Deploy — kadri-worker (Cloudflare)

Cloudflare ანგარიში: `bekachkhirodze1@gmail.com`, Account ID `25aa804574d6b37776f86ab4a6333ad5`
(`wrangler.toml`-ში `account_id`). ყველა ბრძანება `backend/worker`-დან, Node 22-ით:

```sh
export PATH=/opt/homebrew/opt/node@22/bin:$PATH
cd backend/worker && npm ci
npx wrangler whoami
```

## Staging (შექმნილია 2026-10-17)

| რესურსი | სახელი | ID / URL |
|---|---|---|
| Worker | `kadri-worker-staging` | https://kadri-worker-staging.bekachkhirodze1.workers.dev |
| D1 (`DB`) | `kadri-staging` (EEUR) | `3857740b-3d9a-4738-aaa8-14e7d8573789` |
| R2 (`PHOTOS`) | `kadri-photos-staging` | — |

- Migration-ები remote-ზე: `0000_users`, `0001_init`, `0002_usage`, `0003_usage_explain`, `0004_usage_problem` (2026-10-18).
- Secret-ები: `OPENAI_API_KEY`, `SESSION_SECRET`, `GOOGLE_CLIENT_IDS` (iOS + Web client ID მძიმით — `src/auth.ts` `split(",")`),
  `GEMINI_API_KEY` (`/ai/ask` default-ად Gemini-ს იყენებს), `KNOWLEDGE_HUB_KEY`.
- ბოლო deploy: 2026-10-18, ვერსია `1a075bb0-6eb7-44b9-945b-6640386fa4b7` — ერთობლივი მრავალფოტოიანი ანალიზი; იხ. [MULTI_PHOTO_PROBLEM.md](MULTI_PHOTO_PROBLEM.md).
- Vars (`[env.staging.vars]`): `ENVIRONMENT=staging`, `AI_PROVIDER=astra`, `DAILY_SESSION_LIMIT=1000`, `AI_TIMEOUT_MS=60000`.
- `SESSION_SECRET`-ის ასლი მხოლოდ deploy-ის გამკეთებლის მანქანაზეა: `~/.config/kadri/staging.env` (chmod 600, git-ის გარეთ) —
  ფასიანი acceptance-ისთვის dev token-ის მოსაწერად. დაკარგვის შემთხვევაში უბრალოდ დაატრიალე (იხ. ქვემოთ).

### Acceptance (2026-10-17, `live_check.mjs --runs 1` staging-ზე)

| | შედეგი |
|---|---|
| `/ai/parts` p50 latency (სერვერი / wall) | 5.86 წმ / 6.45 წმ (sink 5.9, car 4.1, gym 7.1) — ≤ 8 წმ ✅ |
| meanIoU Python-თან | 0.83 |
| `/ai/steps` (sink) პირველი `step` | 4.0 წმ (სერვერზე 3.9); შემდეგი 4.8 / 8.1 / 11.5 / 16.1, `done` 17.1 წმ |
| SSE ბუფერიზაცია | არ არის — event-ები თანმიმდევრულად მოდის, არა ბოლოს ერთად ✅ |
| ფასი | $0.143 (parts 0.050 + steps 0.094) |

## ჩვეულებრივი deploy

```sh
npx wrangler d1 migrations apply kadri-staging --env staging --remote   # თუ ახალი migration არის — deploy-მდე
npm run deploy:staging
node scripts/deploy_check.mjs https://kadri-worker-staging.bekachkhirodze1.workers.dev --env staging
```

`deploy_check.mjs` უფასოა: `/health` → 200 `{ok:true, env}`, `POST /ai/parts`, `POST /ai/problem` და `GET /sessions` auth-ის გარეშე → 401 JSON.

ფასიანი acceptance (ledger + cap):

```sh
set -a; source ~/.config/kadri/staging.env; set +a      # SESSION_SECRET → dev token
node scripts/live_check.mjs --runs 1 --cap 1 --url https://kadri-worker-staging.bekachkhirodze1.workers.dev
```

Inputs: `experiments/som-test/out_realism/c_astra_tracking/**/input.png` მთავარი checkout-იდან (git-ში არ არის).

მოკლე ფასიანი smoke ახალი route-ებისთვის (თითო ცალი გამოძახება, token იგივე `staging.env`-იდან, არ იბეჭდება):

```sh
node scripts/staging_smoke.mjs ask --image <photo> --out <dir> --box x0,y0,x1,y1         # ≈ $0.002 (Gemini)
node scripts/staging_smoke.mjs steps --image <photo> --out <dir> --parts <parts.json> \
  --instructions <parts_request/request.json> --max-steps 2                              # astra; ჩერდება N step-ზე
```

`/ai/parts`-ის რეგრესია deploy-მდე: [PARTS_REGRESSION_CHECK.md](PARTS_REGRESSION_CHECK.md). `--cap` ≥ $0.30 დატოვე,
თორემ $0.10-იანი რეზერვი მესამე სცენას (gym) აღარ უშვებს.

## Production (ჯერ არ შექმნილა)

იგივე ნაბიჯები `kadri-prod` / `kadri-photos-prod` / `--env production`-ით:

```sh
npx wrangler d1 create kadri-prod                  # database_id → wrangler.toml [[env.production.d1_databases]]
npx wrangler r2 bucket create kadri-photos-prod
npx wrangler d1 migrations apply kadri-prod --env production --remote
npm run deploy:prod                                # worker უნდა არსებობდეს secret-ებამდე

# secret-ები — მნიშვნელობა stdin-ით, არასდროს ჩატში/ლოგში/ფაილში git-ში
( set -a; source <path>/.env; set +a; printf '%s' "$OPENAI_API_KEY" | npx wrangler secret put OPENAI_API_KEY --env production )
openssl rand -base64 48 | tr -d '\n' | npx wrangler secret put SESSION_SECRET --env production   # staging-ისგან განსხვავებული!
printf '%s' '<ios-client-id>,<web-client-id>' | npx wrangler secret put GOOGLE_CLIENT_IDS --env production

node scripts/deploy_check.mjs https://kadri-worker-prod.bekachkhirodze1.workers.dev --env production
```

Production-ზე dev token-ის მოწერა არ გააკეთო — მხოლოდ ნამდვილი Google Sign-In.

## Secret-ების როტაცია

- **`SESSION_SECRET`**: `openssl rand -base64 48 | tr -d '\n' | npx wrangler secret put SESSION_SECRET --env <env>`.
  ახალი ვერსია მაშინვე ეშვება; ყველა არსებული session token (≤ 1 სთ) უქმდება — აპი თავიდან გაივლის `/auth/google`-ს.
  staging-ზე ასლი `~/.config/kadri/staging.env`-ში განაახლე, თუ ფასიანი შემოწმება გჭირდება.
- **`OPENAI_API_KEY`**: OpenAI-ში ახალი key → `secret put` → შეამოწმე (ერთი ფასიანი გამოძახება ან აპით) → ძველი key OpenAI-ში გააუქმე.
- **`GOOGLE_CLIENT_IDS`**: ახალი client ID-ის დამატებისას ჩაწერე სრული სია მძიმით (put ცვლის, არ ამატებს).
- სია: `npx wrangler secret list --env <env>` (მხოლოდ სახელები). წაშლა: `npx wrangler secret delete <NAME> --env <env>`.

## Migration-ები

```sh
npx wrangler d1 migrations list kadri-staging --env staging --remote    # რა არ არის გაშვებული
npx wrangler d1 migrations apply kadri-staging --env staging --remote
npx wrangler d1 execute kadri-staging --env staging --remote --command "SELECT stage, status, COUNT(*), SUM(cost_usd) FROM usage GROUP BY 1,2"
```

ახალი migration: `migrations/000N_<name>.sql`, ჯერ `--local` და ტესტები, მერე staging remote, მერე deploy. ძველ migration-ს არ შეცვალო.

## ლოგები და ხარჯი (Cloudflare dashboard)

- **ლოგები**: dash.cloudflare.com → Workers & Pages → `kadri-worker-staging` → **Logs** (Real-time / Observability).
  ტერმინალიდან: `npx wrangler tail --env staging --format pretty`.
- **Deploy-ები / rollback**: იგივე Worker → **Deployments**; ან `npx wrangler deployments list --env staging`,
  `npx wrangler rollback --env staging`.
- **Cloudflare-ის ხარჯი**: Workers → Overview (requests, CPU); Storage & Databases → D1 → `kadri-staging` → Metrics;
  R2 → `kadri-photos-staging` → Metrics; Billing → Usage.
- **AI ხარჯი** (OpenAI) Cloudflare-ში არ ჩანს: D1 `usage` ცხრილი (`cost_usd`, შეფასება `src/ai/pricing.ts`-ით) — ზემოთ
  `d1 execute` query; ინვოისი — platform.openai.com → Usage.
