DROP TABLE IF EXISTS channels CASCADE;
DROP TABLE IF EXISTS whitelist CASCADE;

CREATE TABLE channels (
    id SERIAL PRIMARY KEY,
    name VARCHAR(50) NOT NULL,
    type VARCHAR(50) NOT NULL
);

CREATE TABLE whitelist (
    id SERIAL PRIMARY KEY,
    fingerprint VARCHAR(32) NOT NULL,
    rank SMALLINT CHECK (rank >= 0 AND rank <= 255) NOT NULL -- must be u8
);