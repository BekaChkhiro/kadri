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

## Deploy (ადამიანმა უნდა გააკეთოს)

1. `npx wrangler login`
2. D1 და R2 შექმნა — ზუსტი ბრძანებები `wrangler.toml`-ის თავშია; დაბეჭდილი `database_id`-ები ჩასვი
   `TODO-set-after-wrangler-d1-create`-ის ნაცვლად.
3. Secret-ები თითო გარემოზე: `npx wrangler secret put OPENAI_API_KEY --env staging`
   (ასევე `GEMINI_API_KEY`, `SESSION_SECRET`, `GOOGLE_CLIENT_IDS`; production-ისთვის `--env production`).
4. `npm run deploy:staging` / `npm run deploy:prod`.

Key-ები არასდროს git-ში — მხოლოდ `.dev.vars` (ლოკალურად) ან `wrangler secret`.
