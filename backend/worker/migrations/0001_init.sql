-- Repair sessions history. Timestamps are ISO 8601 UTC strings, JSON columns hold app-defined arrays.
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  object_name TEXT,
  instructions TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'created' CHECK (status IN ('created', 'parts', 'steps', 'done', 'failed')),
  keyframe_key TEXT,
  parts_json TEXT,
  cost_usd REAL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS sessions_user_created ON sessions (user_id, created_at DESC, id DESC);

CREATE TABLE IF NOT EXISTS steps (
  id INTEGER PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
  idx INTEGER NOT NULL,
  title TEXT NOT NULL,
  text TEXT NOT NULL,
  focus_json TEXT NOT NULL,
  avoid_json TEXT NOT NULL,
  UNIQUE (session_id, idx)
);

CREATE TABLE IF NOT EXISTS feedback (
  id INTEGER PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
  rating INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS feedback_session ON feedback (session_id, created_at);
