-- Transform + Load: from the staging tables into the dimension and the facts.
-- Run by etl.sh in one transaction, after the staging tables were refilled.
-- An existing row is updated, so running it twice changes nothing.

INSERT INTO dim_player (player_id, username, level, xp, registered_at, loaded_at)
SELECT id, username, level, xp, created_at, NOW()
FROM stg_players
ON CONFLICT (player_id) DO UPDATE SET
    username  = EXCLUDED.username,
    level     = EXCLUDED.level,
    xp        = EXCLUDED.xp,
    loaded_at = EXCLUDED.loaded_at;

INSERT INTO fact_session (session_id, name, host_player_id, status, cycles, players,
                          created_at, ended_at, created_day)
SELECT s.id, s.name, s.host_player_id, s.status, s.cycle,
       (SELECT COUNT(*) FROM stg_members m WHERE m.session_id = s.id),
       s.created_at,
       -- the Game Service has no ended_at column: an ended session was last touched when it ended
       CASE WHEN s.status = 'ended' THEN s.updated_at END,
       (s.created_at AT TIME ZONE 'UTC')::date
FROM stg_sessions s
ON CONFLICT (session_id) DO UPDATE SET
    status   = EXCLUDED.status,
    cycles   = EXCLUDED.cycles,
    -- members leave before a session ends, so keep the highest count seen
    players  = GREATEST(fact_session.players, EXCLUDED.players),
    ended_at = EXCLUDED.ended_at;

INSERT INTO fact_action (action_id, session_id, player_id, type, room_id, status,
                         started_at, completed_at, planned_seconds, actual_seconds,
                         xp_awarded, reward_synced, started_day)
SELECT id, session_id, player_id, type, room_id, status,
       started_at, completed_at, duration_seconds,
       EXTRACT(EPOCH FROM completed_at - started_at)::int,
       xp_awarded, reward_synced,
       (started_at AT TIME ZONE 'UTC')::date
FROM stg_actions
ON CONFLICT (action_id) DO UPDATE SET
    status         = EXCLUDED.status,
    completed_at   = EXCLUDED.completed_at,
    actual_seconds = EXCLUDED.actual_seconds,
    xp_awarded     = EXCLUDED.xp_awarded,
    reward_synced  = EXCLUDED.reward_synced;
