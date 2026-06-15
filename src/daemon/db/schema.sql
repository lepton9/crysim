PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;

CREATE TABLE IF NOT EXISTS users (
	id            INTEGER PRIMARY KEY,
	username      TEXT NOT NULL UNIQUE,
	role          TEXT NOT NULL CHECK (role IN ('viewer','trader','admin')),
	password_hash TEXT NOT NULL,
	created_at_ms INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS users_username_idx ON users(username);
