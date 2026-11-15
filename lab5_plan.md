# Lab 5 plan: Sharding and Replication

Source: `wrapper/PAD_LAB_5.pdf`. Ten grades, built in five milestones.

## Requirements, as read from the PDF

Every grade includes the ones below it.

| Grade | Task | Milestone |
|---|---|---|
| 1 | Exist | - |
| 2 | Architecture diagram: add previously implemented but forgotten components | 1 |
| 3 | Architecture diagram: add Data Warehouse, ETL, Cache | 1 |
| 4 | A Data Warehouse database in Docker Compose; a script/job/service that extract-transform-loads from the other databases into it | 1 |
| 5 | Database replication + failover for our private services, minimum 2 replicas | 2 |
| 6 | Caching (Redis/Valkey/...) for commonly accessed GET requests and for authentication data | 3 |
| 7 | Research Consistent Hashing; shard the cache with it (if Redis Cluster is used, be able to compare the two algorithms in detail) | 3 |
| 8 | 2 Phase Commit for functionality that changes 2 or more databases | 4 |
| 9 | Instead of 2PC: long-running saga transactions with the coordinator in the Gateway/Message Broker | 4 |
| 10 | Postman, architecture diagram and Docker Hub in order; new endpoints and DTOs in the README | 5 |

Extra credit (not in this plan): a 5 minute presentation about the PAD journey, up to
+2 points on earlier labs.

## Decisions already made

| Topic | Decision |
|---|---|
| 2PC vs saga | 2PC first, then the saga replaces it on the same flow. Milestone 4 has two commits per repo, so git history proves grade 8; the final code is saga only |
| Replication | `bitnamilegacy/postgresql-repmgr` (streaming replication, automatic promotion, rejoin). Primary + 2 replicas for `player-db` and for `game-db` |
| ETL | A script in this repo (`etl/`), run on a loop in a stock `postgres:16-alpine` container. No new image, no new repo |
| Warehouse | One more Postgres, `warehouse-db` |
| Cache | 3 × `redis:7-alpine`, used from the Gateway. Sharding by **our own** consistent hash ring in the Gateway (not Redis Cluster), so grade 7 is implementation and not configuration |
| Transaction flow | Joining a session: `POST /game/sessions/{id}/players` writes a member row in `game-db` and the `online` flag in `player-db` (today the second write is fire-and-forget) |
| Coordinator | In the Message Broker (it already has SQLite for durable state and reaches every service) |
| Commits | On `main`, subject of at most 10 words, no body, no co-author trailer, `CLAUDE.md` never committed |

## Constraints

- **Teammates' images are not changed.** Replication, 2PC and saga cover our private
  services only (Player, Game). Their databases stay single.
- **One database per service still holds.** The ETL is the one reader of other
  services' databases; it reads from a replica, with a read-only role, and never writes back.
- **The Gateway stays players-only.** Coordinator and saga endpoints live on the broker,
  behind `X-Internal-Key`. The cache has no HTTP surface of its own.
- **No password hashes or tokens in the warehouse or in cache values.** Cache keys of
  tokens are SHA-256 digests.
- **Simple code**: flat Go in the existing layout (`handler.go` / `store.go`), stdlib
  Python in the broker, one new file per feature where possible.
- **The stack grows by ~10 containers** (4 Postgres replicas, 3 Redis, warehouse, ETL).
  Check Docker Desktop has about 8 GB before the defence.
- **Volumes change**: the repmgr image keeps data in another path, so the first run of
  milestone 2 needs `docker compose down -v`.

## What "one commit" means here

Same as Lab 4: a milestone touches several repos, so "5 commits" means **at most one
commit per repo per milestone**, plus the pointer commit here. The exception is
milestone 4, which has two (2PC, then saga).

Images are built locally with the tag compose expects (`fish3008/<repo>:5`) during the
milestones; each touched repo is tagged `5` and published once, in milestone 5.

## The target picture

```
browser ──> Gateway ──> Broker ──> Player ×2 ──> player-db-0 (primary) ══> player-db-1, -2
              │            │       Game ×2   ──> game-db-0   (primary) ══> game-db-1, -2
              │            │                         repmgr promotes a replica on failure
              │            └─ saga coordinator (SQLite): join session = Player step + Game step
              │
              └─ cache: hash ring ──> cache-1 | cache-2 | cache-3   (Redis)
                 GET responses, verified tokens

etl (every 10 s): player-db / game-db replicas ──COPY──> warehouse-db (staging → star schema)
Grafana ──> warehouse-db (analytics panels)
```

---

## Milestone 1: grades 2, 3, 4 (diagram, warehouse, ETL)

Repos: this one only.

**Grades 2 and 3: the diagram.**

- Forgotten components to add to `architecture.mmd`: a database node per service
  (`player-db`, `game-db`, the six teammates' databases as one node), the broker's
  SQLite volume `broker-data`, the outbox tables.
- New: `warehouse-db`, `etl`, `cache` (three nodes + the ring in the Gateway), the
  replicas of `player-db` and `game-db`, the saga coordinator inside the broker box.
  Drawn now as planned; corrected in milestone 5 to the end state.
- Re-render `architecture.png` with the command in `CLAUDE.md`.

**Grade 4: Data Warehouse + ETL.**

- `compose.yml`: `warehouse-db` (`postgres:16-alpine`, volume, schema from
  `etl/warehouse.sql` mounted into `docker-entrypoint-initdb.d`, host port `5440`
  for psql at the defence) and `etl` (`postgres:16-alpine`, mounts `./etl`, runs
  `sh /etl/etl.sh`).
- `etl/warehouse.sql`, a small star schema:
  - `stg_*`: raw copies, truncated every run;
  - `dim_player` (id, username, level, xp, registered_at; **no** password hash);
  - `fact_action` (action id, player, session, type, started, finished, duration, xp awarded, reward synced);
  - `fact_session` (session id, created, ended, players, cycles reached);
  - `etl_runs` (started, finished, rows per table, status).
- `etl/etl.sh`, one loop, `ETL_INTERVAL` seconds (default 10: the Postman run deletes its session after ~25 s):
  1. **Extract**: `psql <source> -c "\copy (SELECT ...) TO STDOUT"` piped into
     `\copy stg_... FROM STDIN` on the warehouse, for Player and Game.
  2. **Transform + Load**: `etl/transform.sql`, plain `INSERT ... SELECT ... ON
     CONFLICT DO UPDATE` from staging into the dimension and facts (derives the
     duration, joins the player, drops what must not leave the service).
  3. Write the `etl_runs` row; print one log line in our format (`[etl-run]`).
- Grafana: a Postgres data source for the warehouse and a row "Analytics" on the
  dashboard (actions per type, XP per player, sessions per day). Cheap, and it is the
  answer to "what is the warehouse for".

Commit here: `grades 2-4: diagram, data warehouse, etl job`.

**Done when:** after a run of the game Postman collection, `SELECT * FROM etl_runs`
shows a successful run, `fact_action` has the actions just played, and the Grafana
row shows them.

---

## Milestone 2: grade 5 (replication + failover)

Repos: this one; Player and Game only if their reconnect needs a fix.

- `compose.yml`: replace `player-db` by `player-db-0`, `-1`, `-2` and `game-db` by
  `game-db-0`, `-1`, `-2` (`bitnamilegacy/postgresql-repmgr:16`, one volume each).
  A YAML anchor per cluster keeps it short. Each node gets `REPMGR_PRIMARY_HOST`,
  `REPMGR_PARTNER_NODES`, `REPMGR_NODE_NAME`, the same credentials as today.
  `max_prepared_transactions=10` is set here too, for milestone 4.
- The services find the primary by themselves, no proxy in between:
  `DATABASE_URL=postgres://user:pass@player-db-0,player-db-1,player-db-2/player?sslmode=disable&target_session_attrs=read-write`.
  pgx tries the hosts in order and keeps the one that accepts writes; after a
  failover the pool's new connections land on the promoted node.
- Check in the Go services (fix only what breaks):
  - Game holds long-lived connections for `LISTEN` and the advisory lock
    (`internal/database`, `hub`, `engine`): they must reconnect after the primary changes;
  - `schema.sql` at startup runs against the primary (it does, through the same URL).
- ETL sources move to the replicas: same host list with `target_session_attrs=prefer-standby`.
- Game's host port `5433` stays, mapped to `game-db-0`.
- Prometheus/Grafana: nothing new needed; failover is shown from logs and psql.

Commits: here `grade 5: postgres replication with repmgr failover`; in Player/Game
only if touched (`reconnect to the new primary after failover`).

**Done when:** `docker stop player-db-0` during a Postman run: after some seconds
(repmgr promotes a replica) requests succeed again, a player registered before the
stop can still log in, and `docker start player-db-0` brings it back as a replica.
`SELECT pg_is_in_recovery()` on each node shows one `f` and two `t`.

To verify first, before writing compose: the exact `bitnamilegacy/postgresql-repmgr`
tag that exists on Docker Hub, and its env name for extra `postgresql.conf` settings.

---

## Milestone 3: grades 6, 7 (cache, consistent hashing)

Repos: Gateway, this one.

**Grade 6: caching in the Gateway.** New file `app/cache.py`, `redis` (asyncio) in
`requirements.txt`.

- **GET responses**, for an allow-list in `config.py` (pattern → TTL):

  | Route | TTL | Why |
  |---|---|---|
  | `GET /players/items` (catalog) | 300 s | read by every client, never changes |
  | `GET /players/{id}` | 30 s | the most common lookup |
  | `GET /players/{id}/inventory` | 10 s | common, changes by trades |
  | `GET /world/rooms`, `/world/rooms/{id}` | 60 s | a teammate's static map |

  Key: `get:<path>?<query>`; value: status, content type, body. Only `200` is stored.
  A non-GET that succeeds on `/players/{id}/...` or `/trades/...` deletes that
  player's keys. Changes that do not pass the Gateway (XP from Game) are covered by
  the short TTL.
- **Authentication data**: after a token is verified, `auth:<sha256(token)>` →
  player id, TTL = time left until `exp` (at most 5 minutes). The next request with
  that token skips the signature check. `POST /auth/logout` (answered by the
  Gateway) deletes the entry and stores `revoked:<sha256>` until `exp`, so a logged
  out token stops working: that is what the cache buys beyond speed.
- Every response says `X-Cache: HIT|MISS|-` and `X-Cache-Node: cache-2`; the log line
  gets `cache=hit`; metrics `gateway_cache_hits_total` / `_misses_total` by node.
- **The cache is optional at runtime**: any Redis error is a miss (short timeout,
  one WARN line), never a failed request.

**Grade 7: sharding by consistent hashing.**

- `compose.yml`: `cache-1`, `cache-2`, `cache-3` (`redis:7-alpine`,
  `--maxmemory 64mb --maxmemory-policy allkeys-lru`, no persistence);
  Gateway gets `CACHE_NODES=cache-1:6379,cache-2:6379,cache-3:6379`.
- `app/hashring.py`, about 40 lines, ours:
  - each node is placed on a ring at 100 points (`md5("cache-1#17")`), sorted list;
  - a key goes to the first point clockwise from `md5(key)` (`bisect`);
  - a node that fails is skipped for 10 s: its keys go to the next node on the
    ring, everyone else's keys stay where they are.
- Research notes for the defence (go into `defending.md` in milestone 5): why
  `hash % N` remaps almost every key when N changes and the ring only ~1/N; virtual
  nodes for an even spread; and the comparison with Redis Cluster (16384 fixed hash
  slots, `CRC16(key) % 16384`, slots assigned to nodes and moved explicitly, `MOVED`
  redirects, hash tags) versus our ring (positions from the node name, nothing to
  migrate, the client decides).

Commits: gateway `grades 6-7: redis cache with consistent hash ring`; here
`grades 6-7: three cache nodes, gateway cache settings`.

**Done when:** the second `GET /players/items` answers `X-Cache: HIT`; `redis-cli
dbsize` shows keys on all three nodes; `docker stop cache-2` loses only its share
(the others still hit) and no request fails; a logged out token gets `401`.

---

## Milestone 4: grades 8, 9 (2PC, then saga)

Repos: Broker, Gateway, Player, Game, this one. **Two commits per repo.**

The flow in both steps: a player joins a session. Today Game inserts the member and
then tells Player `online=true` from a goroutine, without caring if it lands. After
this milestone both writes are one distributed transaction, coordinated by the
broker. The Gateway sends `POST /game/sessions/{id}/players` to the coordinator
instead of Game's queue (one entry in a small `COORDINATED` table in its config).

### Step A: grade 8, Two Phase Commit

- Participants (Player and Game), REST for services, through the broker with the key:
  - `POST /<prefix>/internal/tx/{txId}/prepare`: `BEGIN`, do the work (Player: set
    `online`; Game: `AddMember` with all its checks), `PREPARE TRANSACTION '<txId>'`.
    Answers `200` = vote yes, `409` with the reason = vote no (nothing prepared).
  - `POST .../commit`: `COMMIT PREPARED`; `POST .../rollback`: `ROLLBACK PREPARED`.
    Both are idempotent (an unknown id is `200`).
- Coordinator in the broker, `app/twophase.py`:
  - `POST /transactions/join-session` `{session_id, player_id}`;
  - writes the transaction to SQLite (`preparing`), sends `prepare` to both; all yes →
    writes `committing` (the decision), sends `commit` to both, `committed`;
    any no or error → `rollback` to those that prepared, `aborted`, and the
    participant's reason goes back to the client with its status;
  - at start: every `committing` transaction is committed again, every `preparing`
    one rolled back, so no prepared transaction stays locked after a crash;
  - `GET /transactions` lists them (key required).
- Game's `join` handler loses `presenceAsync`; its checks and `AddMember` move behind `prepare`.

Commits: `grade 8: two phase commit for joining a session` in broker, gateway,
player, game; pointers here.

**Done when:** a join shows `prepare → commit` for both participants in the broker
log and the player is `online`; joining a full session answers `409` and
`pg_prepared_xacts` is empty on both databases; killing the broker between prepare
and commit, then starting it, finishes the transaction.

### Step B: grade 9, saga instead

- `app/twophase.py` and the `tx` endpoints are deleted; `app/saga.py` replaces them.
  A saga is a list of steps, each a normal local transaction plus its compensation:

  | # | Step | Compensation |
  |---|---|---|
  | 1 | Player: `online = true` | Player: `online = false` |
  | 2 | Game: add the member (can refuse: full, ended, already a member) | Game: remove the member |

  The steps are the routes that already exist (`presence`, `POST` and `DELETE` on
  `/game/sessions/{id}/players`), called through the broker's own queues with
  `X-Saga-Id`, so Player and Game need almost no new code.
- Coordinator: `POST /sagas/join-session` runs the steps in order, writing each step's
  state to SQLite before and after the call. A step that fails → the compensations
  of the finished steps run in reverse order, retried with backoff until they
  succeed. States: `running`, `completed`, `compensating`, `compensated`.
- **Long-running**: the state is on disk and a worker thread drives it, so a saga
  survives a broker restart and continues where it stopped; a step may take as long
  as it needs, nothing is locked in between (the difference from 2PC to say out loud).
- `GET /sagas`, `GET /sagas/{id}` (key required) show every step and compensation with
  times; metrics `broker_sagas_total{saga, outcome}`; log tag `[broker-saga]`.
- The same coordinator takes "leave session" as a second saga if time allows; not needed for the grade.

Commits: `grade 9: saga coordinator replaces two phase commit` in broker, gateway,
player, game; pointers here.

**Done when:** a join shows two completed steps in `GET /sagas/{id}`; joining a full
session ends `compensated` and the player is `online = false` again; stopping the
broker mid-saga and starting it finishes or compensates it.

---

## Milestone 5: grade 10 (everything in order)

Repos: all touched ones, this one.

- **README** (here and per service): every new endpoint with its DTOs: the cache
  headers and `POST /auth/logout` (Gateway); `/sagas/...` (Broker); the warehouse
  schema and ETL; the replication setup and how to watch a failover. Remove what the
  saga replaced.
- **`architecture.mmd` / `.png`**: final state, re-rendered.
- **Postman**: `postman/lab5-defence.postman_collection.json`, one folder per grade
  (4: warehouse rows through Grafana's API; 6-7: HIT/MISS, node header, logout;
  8-9: saga happy path, compensated path, listing). Old collections re-run and fixed.
- **`lab5-tests.ps1`**: the parts Postman cannot do: `Test-Failover` (stop a primary),
  `Test-CacheNodeDown`, `Test-SagaBrokerRestart`, `Show-Warehouse`.
- **`defending.md`**: a Lab 5 section per grade, in the Lab 4 shape (what to say, what
  to run, where the code is, likely questions), including the Consistent Hashing
  research and the 2PC vs saga comparison (with the commit that had 2PC).
- **`flow.md`, `CLAUDE.md`, `.env.example`**: updated (`CLAUDE.md` stays uncommitted).
- **Docker Hub**: tag `5` on every touched repo (gateway, broker, player, game) →
  CI publishes `fish3008/<repo>:5` and `:latest`; compose defaults move to `5`; the
  `build:` lines and "until tag 4 is published" comments go; a clean
  `docker compose pull && up` on published images is the final check.

Commits: `grade 10: readme endpoints and dtos` in each touched service; here
`grade 10: postman, diagram, docs, image tags 5`.

**Done when:** `docker compose down -v; docker compose pull; docker compose up -d`
works with no local build, both Lab 5 test files pass, and every old collection still passes.

---

## Order and dependencies

```
M1 warehouse + ETL ──> M2 replication (ETL moves to replicas; max_prepared_transactions set)
                                   └──> M4A 2PC ──> M4B saga
M3 cache (independent of M2 and M4)                         ──> M5 docs, Postman, publish
```

Milestone 3 can be done before milestone 2 if a defence date needs it.
