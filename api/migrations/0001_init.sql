-- Devices that proved they're the genuine app (App Attest).
CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  key_id TEXT NOT NULL,
  public_key TEXT NOT NULL,
  counter INTEGER NOT NULL DEFAULT 0,
  env TEXT NOT NULL,
  created INTEGER NOT NULL
);

-- One-time values the app gets attested against.
CREATE TABLE challenges (
  value TEXT PRIMARY KEY,
  created INTEGER NOT NULL
);

-- One row per run per board. Boards show each driver's best per car.
CREATE TABLE entries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  device TEXT NOT NULL,
  handle TEXT NOT NULL,
  make TEXT NOT NULL,
  model TEXT NOT NULL,
  year INTEGER NOT NULL,
  trim TEXT NOT NULL DEFAULT '',
  country TEXT,
  metric TEXT NOT NULL,
  value REAL NOT NULL,
  verified INTEGER NOT NULL DEFAULT 0,
  grade REAL,
  created INTEGER NOT NULL,
  reports INTEGER NOT NULL DEFAULT 0,
  hidden INTEGER NOT NULL DEFAULT 0,
  UNIQUE (run_id, metric)
);
CREATE INDEX entries_board ON entries (metric, hidden, value);
CREATE INDEX entries_device ON entries (device, created);

CREATE TABLE reports (
  entry INTEGER NOT NULL,
  device TEXT NOT NULL,
  created INTEGER NOT NULL,
  PRIMARY KEY (entry, device)
);
