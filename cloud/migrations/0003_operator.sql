-- Operator role (a PA who can also run the CG Macs' local control GUI) + one-time sign-in codes for the Macs.

-- SQLite can't change a CHECK constraint in place: rebuild users.
CREATE TABLE users_new (
  email      TEXT PRIMARY KEY,
  name       TEXT,
  role       TEXT NOT NULL DEFAULT 'pa' CHECK (role IN ('pa', 'operator', 'production', 'admin')),
  created_at TEXT NOT NULL,
  last_seen  TEXT
);
INSERT INTO users_new (email, name, role, created_at, last_seen) SELECT email, name, role, created_at, last_seen FROM users;
DROP TABLE users;
ALTER TABLE users_new RENAME TO users;

-- A code is handed to the browser in the redirect back to the Mac and redeemed once by that Mac (device API).
CREATE TABLE operator_codes (
  code_hash  TEXT PRIMARY KEY,
  email      TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  used_at    TEXT,
  used_by    TEXT
);
CREATE INDEX operator_codes_expires ON operator_codes(expires_at);
