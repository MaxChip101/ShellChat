CREATE TABLE IF NOT EXISTS channels (
    id SERIAL PRIMARY KEY,
    name VARCHAR(32) UNIQUE NOT NULL,
    type VARCHAR(16) NOT NULL,
    rank SMALLINT NOT NULL CHECK (rank >= 0 AND rank <= 255) -- must be u8
);

CREATE TABLE IF NOT EXISTS whitelist (
    id SERIAL PRIMARY KEY,
    fingerprint BYTEA UNIQUE NOT NULL CHECK (octet_length(fingerprint) = 32),
    rank SMALLINT NOT NULL CHECK (rank >= 0 AND rank <= 255) -- must be u8
);
