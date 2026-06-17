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

CREATE TABLE IF NOT EXISTS assets (
	symbol   TEXT PRIMARY KEY,
	decimals INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS balances (
	user_id      INTEGER NOT NULL,
	asset        TEXT NOT NULL,
	amount_minor INTEGER NOT NULL,
	PRIMARY KEY (user_id, asset),
	FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
	FOREIGN KEY (asset) REFERENCES assets(symbol)
);

CREATE INDEX IF NOT EXISTS balances_user_id_idx ON balances(user_id);

-- Cost basis for unrealized PnL.
CREATE TABLE IF NOT EXISTS positions (
	user_id              INTEGER NOT NULL,
	asset                TEXT NOT NULL,
	qty_minor            INTEGER NOT NULL,
	cost_basis_usd_cents INTEGER NOT NULL,
	PRIMARY KEY (user_id, asset),
	FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
	FOREIGN KEY (asset) REFERENCES assets(symbol)
);

CREATE INDEX IF NOT EXISTS positions_user_id_idx ON positions(user_id);

-- Trades represent buy/sell activity only.
CREATE TABLE IF NOT EXISTS trades (
	id                         INTEGER PRIMARY KEY,
	user_id                    INTEGER NOT NULL,
	ts_ms                      INTEGER NOT NULL,
	side                       TEXT NOT NULL CHECK (side IN ('buy','sell')),
	asset                      TEXT NOT NULL,
	qty_minor                  INTEGER NOT NULL,
	price_usd_cents            INTEGER NOT NULL,
	usd_gross_cents            INTEGER NOT NULL,
	fee_usd_cents              INTEGER NOT NULL,
	usd_net_cents              INTEGER NOT NULL,
	FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
	FOREIGN KEY (asset) REFERENCES assets(symbol)
);

CREATE INDEX IF NOT EXISTS trades_user_id_ts_idx ON trades(user_id, ts_ms DESC);
CREATE INDEX IF NOT EXISTS trades_user_id_asset_ts_idx ON trades(user_id, asset, ts_ms DESC);

-- Cashflows are non-trade balance changes: deposits, withdrawals.
CREATE TABLE IF NOT EXISTS cashflows (
	id          INTEGER PRIMARY KEY,
	user_id     INTEGER NOT NULL,
	ts_ms       INTEGER NOT NULL,
	asset       TEXT NOT NULL,
	amount_minor INTEGER NOT NULL,
	kind        TEXT NOT NULL,
	FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
	FOREIGN KEY (asset) REFERENCES assets(symbol)
);

CREATE INDEX IF NOT EXISTS cashflows_user_id_ts_idx ON cashflows(user_id, ts_ms DESC);

INSERT OR IGNORE INTO assets(symbol, decimals) VALUES ('USD', 2);
INSERT OR IGNORE INTO assets(symbol, decimals) VALUES ('BTC', 8);
INSERT OR IGNORE INTO assets(symbol, decimals) VALUES ('ETH', 8);
