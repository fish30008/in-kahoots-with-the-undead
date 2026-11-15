#!/bin/bash
# Start of every node of the replicated databases (player-db, game-db): a guard
# against two primaries, then the image's own start.
#
# The image decides at start whether a node is the primary or a replica by asking
# its partners. A node that was the primary and is started again while a failover
# is still going on gets no clear answer (one partner is promoted, the other has
# not followed it yet, or nobody is promoted yet) and then keeps the primary role:
# two primaries. So a node that already has data waits here until its partners
# agree, and only then lets the image decide.

me="$REPMGR_NODE_NETWORK_NAME"
WAIT_SECONDS="${GUARD_WAIT_SECONDS:-90}"

log() {
    level="$1"
    shift
    printf '%s %-5s [db-guard] %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$me" "$*"
}

# ask <node> <sql>: one value from a partner, as the superuser; fails when it is down.
ask() {
    PGPASSWORD="$POSTGRESQL_POSTGRES_PASSWORD" PGCONNECT_TIMEOUT=2 \
        psql -h "$1" -U postgres -d postgres -Atc "$2" 2>/dev/null
}

# agreed: true when it is safe to start. Sets $why.
agreed() {
    up=0
    primaries=""
    lost=""
    for node in ${REPMGR_PARTNER_NODES//,/ }; do
        [ "$node" = "$me" ] && continue
        recovering="$(ask "$node" "select pg_is_in_recovery()")" || continue
        up=$((up + 1))
        if [ "$recovering" = "f" ]; then
            primaries="$primaries $node"
        else
            # a replica: whose WAL is it receiving right now?
            upstream="$(ask "$node" "select sender_host from pg_stat_wal_receiver where status = 'streaming'")"
            lost="$lost $node:$upstream"
        fi
    done

    if [ "$up" -eq 0 ]; then
        why="no partner is up, the image decides alone"
        return 0
    fi

    set -- $primaries
    if [ "$#" -ne 1 ]; then
        why="$# primaries among the partners ($up up), a failover is not finished"
        return 1
    fi
    primary="$1"

    for pair in $lost; do
        if [ "${pair#*:}" != "$primary" ]; then
            why="${pair%%:*} does not follow $primary yet"
            return 1
        fi
    done

    why="the partners agree: $primary is the primary"
    return 0
}

# Only a node with data can come back as a stale primary; a new one clones anyway.
if [ -f "${POSTGRESQL_DATA_DIR:-/bitnami/postgresql/data}/PG_VERSION" ]; then
    waited=0
    until agreed; do
        if [ "$waited" -ge "$WAIT_SECONDS" ]; then
            log WARN "no agreement after ${WAIT_SECONDS}s ($why), starting anyway"
            break
        fi
        [ "$waited" -eq 0 ] && log INFO "waiting before start: $why"
        sleep 2
        waited=$((waited + 2))
    done
    [ "$waited" -lt "$WAIT_SECONDS" ] && log INFO "starting after ${waited}s: $why"
fi

exec /opt/bitnami/scripts/postgresql-repmgr/entrypoint.sh /opt/bitnami/scripts/postgresql-repmgr/run.sh
