-- The Data Warehouse (Lab 5): what the ETL job (etl.sh) fills from the Player and
-- Game databases. Applied once, when the warehouse-db volume is created.
--
-- stg_*  : raw copies of the source rows, emptied and refilled on every run
-- dim_*  : who (the player)
-- fact_* : what happened (sessions, actions)

-- Staging: only the columns the warehouse needs. Password hashes, emails and the
-- outbox never leave the Player Service.
CREATE TABLE IF NOT EXISTS stg_players (
    id         BIGINT,
    username   TEXT,
    xp         INTEGER,
    level      INTEGER,
    created_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS stg_sessions (
    id             UUID,
    name           TEXT,
    host_player_id BIGINT,
    status         TEXT,
    cycle          INTEGER,
    created_at     TIMESTAMPTZ,
    updated_at     TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS stg_members (
    session_id UUID,
    player_id  BIGINT
);

CREATE TABLE IF NOT EXISTS stg_actions (
    id               UUID,
    session_id       UUID,
    player_id        BIGINT,
    type             TEXT,
    room_id          BIGINT,
    status           TEXT,
    duration_seconds INTEGER,
    started_at       TIMESTAMPTZ,
    completed_at     TIMESTAMPTZ,
    xp_awarded       INTEGER,
    reward_synced    BOOLEAN
);

-- One row per player, as of the last run.
CREATE TABLE IF NOT EXISTS dim_player (
    player_id     BIGINT PRIMARY KEY,
    username      TEXT NOT NULL,
    level         INTEGER NOT NULL,
    xp            INTEGER NOT NULL,
    registered_at TIMESTAMPTZ NOT NULL,
    loaded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- One row per game session. A session deleted in the Game Service stays here:
-- the warehouse keeps history.
CREATE TABLE IF NOT EXISTS fact_session (
    session_id     UUID PRIMARY KEY,
    name           TEXT NOT NULL,
    host_player_id BIGINT NOT NULL,
    status         TEXT NOT NULL,
    cycles         INTEGER NOT NULL,
    -- the most players seen in it at once, over all runs
    players        INTEGER NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL,
    ended_at       TIMESTAMPTZ,
    created_day    DATE NOT NULL
);

-- One row per timed action.
CREATE TABLE IF NOT EXISTS fact_action (
    action_id        UUID PRIMARY KEY,
    session_id       UUID NOT NULL,
    player_id        BIGINT NOT NULL,
    type             TEXT NOT NULL,
    room_id          BIGINT NOT NULL,
    status           TEXT NOT NULL,
    started_at       TIMESTAMPTZ NOT NULL,
    completed_at     TIMESTAMPTZ,
    -- what the action was planned to take, and what it really took
    planned_seconds  INTEGER NOT NULL,
    actual_seconds   INTEGER,
    xp_awarded       INTEGER NOT NULL,
    reward_synced    BOOLEAN NOT NULL,
    started_day      DATE NOT NULL
);

CREATE INDEX IF NOT EXISTS fact_action_player_idx ON fact_action (player_id);
CREATE INDEX IF NOT EXISTS fact_action_type_idx ON fact_action (type);

-- One row per run of the ETL job.
CREATE TABLE IF NOT EXISTS etl_runs (
    id          BIGSERIAL PRIMARY KEY,
    started_at  TIMESTAMPTZ NOT NULL,
    finished_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status      TEXT NOT NULL CHECK (status IN ('ok', 'failed')),
    players     INTEGER NOT NULL DEFAULT 0,
    sessions    INTEGER NOT NULL DEFAULT 0,
    actions     INTEGER NOT NULL DEFAULT 0,
    error       TEXT
);
