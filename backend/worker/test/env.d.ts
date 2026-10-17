// Types for `cloudflare:workers` `env` / `exports` inside tests.
declare namespace Cloudflare {
  interface GlobalProps {
    mainModule: typeof import("../src/index");
  }
  interface Env extends import("../src/env").Env {}
}
