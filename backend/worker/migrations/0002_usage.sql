-- One row per paid AI request. stage='parts' marks a started session (daily limit counts these).
-- user_id = users.id (Google `sub`), session_id is nullable and intentionally not a foreign key.
-- Timestamps are ISO 8601 UTC strings (Date.toISOString()), so lexical order = time order.
CREATE TABLE IF NOT EXISTS usage (
  id INTEGER PRIMARY KEY,
  user_id TEXT NOT NULL,
  session_id TEXT,
  stage TEXT NOT NULL CHECK (stage IN ('parts', 'steps')),
  provider TEXT NOT NULL,
  model TEXT NOT NULL,
  input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  reasoning_tokens INTEGER NOT NULL DEFAULT 0,
  cost_usd REAL NOT NULL DEFAULT 0,
  latency_ms INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL CHECK (status IN ('ok', 'error', 'timeout')),
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS usage_user_created ON usage (user_id, created_at);
