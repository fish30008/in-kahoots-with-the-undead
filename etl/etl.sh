#!/bin/sh
# The ETL job (Lab 5): every ETL_INTERVAL seconds, copy what the warehouse needs out
# of the Player and Game databases and load it into the Data Warehouse.
#
#   Extract    psql \copy (SELECT ...) TO STDOUT on the source, piped into
#              \copy stg_... FROM STDIN on the warehouse
#   Transform  transform.sql: staging -> dim_player, fact_session, fact_action
#   Load       the same statements, INSERT ... ON CONFLICT DO UPDATE
#
# It runs in a stock postgres image: psql is the only tool it needs.
set -o pipefail

INTERVAL="${ETL_INTERVAL:-10}"
DIR="$(dirname "$0")"

# The sources are only ever read: a write by mistake is refused by the session.
SOURCE_OPTIONS="-c default_transaction_read_only=on"

log() {
    level="$1"
    shift
    printf '%s %-5s [etl-run] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*"
}

warehouse() {
    psql "$WAREHOUSE_DB_URL" -q -v ON_ERROR_STOP=1 "$@"
}

# extract <source url> <staging table> <select>: one table from a source into staging.
extract() {
    PGOPTIONS="$SOURCE_OPTIONS" psql "$1" -q -v ON_ERROR_STOP=1 -c "\\copy ($3) TO STDOUT" |
        warehouse -c "\\copy $2 FROM STDIN"
}

run() {
    warehouse -c "TRUNCATE stg_players, stg_sessions, stg_members, stg_actions" || return 1

    extract "$PLAYER_DB_URL" stg_players \
        "SELECT id, username, xp, level, created_at FROM players" || return 1
    extract "$GAME_DB_URL" stg_sessions \
        "SELECT id, name, host_player_id, status, cycle, created_at, updated_at FROM sessions" || return 1
    extract "$GAME_DB_URL" stg_members \
        "SELECT session_id, player_id FROM session_members" || return 1
    extract "$GAME_DB_URL" stg_actions \
        "SELECT id, session_id, player_id, type, room_id, status, duration_seconds, started_at, completed_at, xp_awarded, reward_synced FROM actions" || return 1

    # one transaction: the facts are never half loaded
    warehouse -1 -f "$DIR/transform.sql" || return 1
}

log INFO "every ${INTERVAL}s: player and game databases -> warehouse"

last=""
while true; do
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    begin="$(date +%s)"

    if error="$(run 2>&1)"; then
        counts="$(warehouse -At -F ' ' -c "SELECT (SELECT COUNT(*) FROM stg_players), (SELECT COUNT(*) FROM stg_sessions), (SELECT COUNT(*) FROM stg_actions)")"
        set -- $counts
        warehouse -c "INSERT INTO etl_runs (started_at, status, players, sessions, actions) VALUES ('$started', 'ok', $1, $2, $3)"
        now="ok players=$1 sessions=$2 actions=$3"
        # an idle system writes nothing: one line only when the numbers changed
        if [ "$now" != "$last" ]; then
            log INFO "loaded players=$1 sessions=$2 actions=$3 in $(($(date +%s) - begin))s"
        fi
    else
        error="$(printf '%s' "$error" | tr '\n' ' ' | tr -d "'")"
        warehouse -c "INSERT INTO etl_runs (started_at, status, error) VALUES ('$started', 'failed', '$error')" 2>/dev/null
        now="failed"
        if [ "$now" != "$last" ]; then
            log WARN "run failed, trying again in ${INTERVAL}s: err=\"$error\""
        fi
    fi
    last="$now"

    # keep a week of run history
    warehouse -c "DELETE FROM etl_runs WHERE started_at < NOW() - INTERVAL '7 days'" 2>/dev/null

    sleep "$INTERVAL"
done
