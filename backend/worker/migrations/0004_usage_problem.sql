-- Add multi-photo problem usage without rewriting historical records.
CREATE TABLE usage_next (
  id INTEGER PRIMARY KEY,
  user_id TEXT NOT NULL,
  session_id TEXT,
  stage TEXT NOT NULL CHECK (stage IN ('parts', 'steps', 'explain', 'ask', 'problem')),
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

INSERT INTO usage_next SELECT id, user_id, session_id, stage, provider, model, input_tokens, output_tokens,
  reasoning_tokens, cost_usd, latency_ms, status, created_at FROM usage;

DROP TABLE usage;

ALTER TABLE usage_next RENAME TO usage;

CREATE INDEX IF NOT EXISTS usage_user_created ON usage (user_id, created_at);
