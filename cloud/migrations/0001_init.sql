-- LifeCG notes platform: initial schema

CREATE TABLE campuses (
  id               TEXT PRIMARY KEY,
  name             TEXT NOT NULL,
  default_theme_id TEXT NOT NULL,
  sort             INTEGER NOT NULL DEFAULT 0
);

-- Who gets the PDF email for a campus (edited in the portal; never seeded with real addresses)
CREATE TABLE campus_recipients (
  campus_id TEXT NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
  email     TEXT NOT NULL,
  name      TEXT,
  PRIMARY KEY (campus_id, email)
);

CREATE TABLE users (
  email      TEXT PRIMARY KEY,
  name       TEXT,
  role       TEXT NOT NULL DEFAULT 'pa' CHECK (role IN ('pa', 'production', 'admin')),
  created_at TEXT NOT NULL,
  last_seen  TEXT
);

CREATE TABLE messages (
  id            TEXT PRIMARY KEY,
  title         TEXT NOT NULL DEFAULT '',
  speaker       TEXT NOT NULL DEFAULT '',
  speaker_email TEXT,
  created_by    TEXT NOT NULL,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  source_text   TEXT NOT NULL DEFAULT '',
  blocks_json   TEXT NOT NULL DEFAULT '[]',
  slides_json   TEXT NOT NULL DEFAULT '[]'
);
CREATE INDEX messages_created_by ON messages(created_by, updated_at);
CREATE INDEX messages_updated ON messages(updated_at);

-- A service = campus + start time. starts_at keeps the local offset (+13:00); starts_utc sorts/filters.
CREATE TABLE services (
  id         TEXT PRIMARY KEY,
  campus_id  TEXT NOT NULL REFERENCES campuses(id),
  starts_at  TEXT NOT NULL,
  starts_utc TEXT NOT NULL,
  label      TEXT NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE (campus_id, starts_utc)
);
CREATE INDEX services_starts ON services(starts_utc);

-- Every push is a new version of a service's notes (snapshot of the message at push time).
CREATE TABLE service_notes (
  service_id  TEXT NOT NULL REFERENCES services(id) ON DELETE CASCADE,
  version     INTEGER NOT NULL,
  message_id  TEXT NOT NULL REFERENCES messages(id),
  theme_id    TEXT NOT NULL,
  title       TEXT NOT NULL,
  speaker     TEXT NOT NULL,
  slides_json TEXT NOT NULL,
  pushed_by   TEXT NOT NULL,
  pushed_at   TEXT NOT NULL,
  pdf_key     TEXT,
  emailed_at  TEXT,
  email_error TEXT,
  PRIMARY KEY (service_id, version)
);
CREATE INDEX service_notes_message ON service_notes(message_id);

CREATE TABLE devices (
  id                TEXT PRIMARY KEY,
  name              TEXT NOT NULL,
  campus_id         TEXT NOT NULL REFERENCES campuses(id),
  token_hash        TEXT NOT NULL UNIQUE,
  control_url       TEXT,
  created_by        TEXT,
  created_at        TEXT NOT NULL,
  last_seen         TEXT,
  app_version       TEXT,
  loaded_service_id TEXT,
  loaded_version    INTEGER
);
