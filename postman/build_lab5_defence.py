import json
import sys

OUT = sys.argv[1]


def req(name, method, url, tests, body=None, headers=None, desc=None, pre=None):
    r = {"name": name, "request": {"method": method,
                                   "header": [{"key": k, "value": v} for k, v in (headers or {}).items()],
                                   "url": url}}
    if desc:
        r["request"]["description"] = desc
    if body is not None:
        r["request"]["header"].append({"key": "Content-Type", "value": "application/json"})
        r["request"]["body"] = {"mode": "raw", "raw": json.dumps(body, indent=2).replace('"{{playerId}}"', "{{playerId}}").replace('"{{joinerId}}"', "{{joinerId}}").replace('"{{offlineId}}"', "{{offlineId}}")}
    ev = [{"listen": "test", "script": {"type": "text/javascript", "exec": tests}}]
    if pre:
        ev.insert(0, {"listen": "prerequest", "script": {"type": "text/javascript", "exec": pre}})
    r["event"] = ev
    return r


def sql(q):
    return {"from": "now-1h", "to": "now",
            "queries": [{"refId": "A", "datasource": {"uid": "warehouse"}, "rawSql": q, "format": "table"}]}


ROWS = [
    "const frame = pm.response.json().results.A.frames[0];",
    "const names = frame.schema.fields.map(f => f.name);",
    "const cols = frame.data.values;",
    "const rows = (cols[0] || []).map((_, i) => Object.fromEntries(names.map((n, c) => [n, cols[c][i]])));",
]
AUTH = {"Authorization": "Bearer {{token}}"}
DW = "{{grafanaUrl}}/api/ds/query"
WAIT = [
    "// the ETL job runs every 10 s: ask again, up to 8 times, until the row is there",
    "const tries = Number(pm.collectionVariables.get('tries') || 0);",
    "if (rows.length === 0 && tries < 8) {",
    "    pm.collectionVariables.set('tries', tries + 1);",
    "    setTimeout(() => {}, 3000);",
    "    postman.setNextRequest(pm.info.requestName);",
    "    return;",
    "}",
    "pm.collectionVariables.set('tries', 0);",
]

setup = [
    req("Register a player", "POST", "{{gatewayUrl}}/auth/register",
        ["pm.test('201: the player is created', () => pm.response.to.have.status(201));",
         "pm.collectionVariables.set('playerId', pm.response.json().id);"],
        body={"username": "{{user}}", "password": "{{password}}"},
        pre=["pm.collectionVariables.set('user', 'lab5_' + Date.now());",
             "pm.collectionVariables.set('tries', 0);"]),
    req("Log in", "POST", "{{gatewayUrl}}/auth/login",
        ["pm.test('200 and a token', () => { pm.response.to.have.status(200); pm.expect(pm.response.json().access_token).to.be.a('string'); });",
         "pm.collectionVariables.set('token', pm.response.json().access_token);"],
        body={"username": "{{user}}", "password": "{{password}}"}),
]

g4 = [
    req("The ETL job runs: its last run is ok", "POST", DW, ROWS + [
        "pm.test('etl_runs has a run', () => pm.expect(rows.length).to.equal(1));",
        "pm.test('the last run is ok', () => pm.expect(rows[0].status).to.equal('ok'));",
        "pm.test('it finished less than a minute ago', () => pm.expect(rows[0].age_seconds).to.be.below(60));"],
        body=sql("SELECT status, players, sessions, actions, EXTRACT(EPOCH FROM NOW() - finished_at)::int AS age_seconds FROM etl_runs ORDER BY id DESC LIMIT 1"),
        desc="Asked through Grafana's Warehouse data source, so no database port or password is needed."),
    req("Extract + load: the new player reached dim_player", "POST", DW, ROWS + WAIT + [
        "pm.test('the player registered in Setup is in the warehouse', () => pm.expect(rows.length).to.equal(1));",
        "pm.test('with its username, level 1 and 0 xp', () => { pm.expect(rows[0].username).to.equal(pm.collectionVariables.get('user')); pm.expect(rows[0].level).to.equal(1); pm.expect(rows[0].xp).to.equal(0); });"],
        body=sql("SELECT player_id, username, level, xp FROM dim_player WHERE player_id = {{playerId}}"),
        desc="Player Service database -> stg_players -> dim_player. Repeats itself until the next ETL run has happened."),
    req("Nothing private was copied: no password or email column", "POST", DW, ROWS + [
        "const columns = rows.map(r => r.column_name);",
        "pm.test('dim_player and stg_players have columns', () => pm.expect(columns.length).to.be.above(5));",
        "pm.test('none of them is a password or an email', () => pm.expect(columns.filter(c => /password|email/.test(c))).to.eql([]));"],
        body=sql("SELECT table_name || '.' || column_name AS column_name FROM information_schema.columns WHERE table_name IN ('dim_player', 'stg_players')")),
    req("Create a session (a row for the Game side)", "POST", "{{gatewayUrl}}/game/sessions",
        ["pm.test('201: the session is created', () => pm.response.to.have.status(201));",
         "pm.collectionVariables.set('sessionId', pm.response.json().id);"],
        body={"name": "lab5 warehouse", "host_player_id": "{{playerId}}"}, headers=AUTH),
    req("Transform: the session reached fact_session, players counted", "POST", DW, ROWS + WAIT + [
        "pm.test('the session is in the warehouse', () => pm.expect(rows.length).to.equal(1));",
        "pm.test('status active, 1 player (counted from the members), day column filled', () => { pm.expect(rows[0].status).to.equal('active'); pm.expect(rows[0].players).to.equal(1); pm.expect(rows[0].created_day).to.be.a('string'); });"],
        body=sql("SELECT status, players, created_day::text AS created_day FROM fact_session WHERE session_id = '{{sessionId}}'"),
        desc="Game Service database -> stg_sessions + stg_members -> fact_session. `players` and `created_day` do not exist in the source: the transform derives them."),
    req("Delete the session in the Game Service", "DELETE", "{{gatewayUrl}}/game/sessions/{{sessionId}}",
        ["pm.test('204: gone from the Game Service', () => pm.response.to.have.status(204));"], headers=AUTH),
    req("History: the deleted session is still in the warehouse", "POST", DW, ROWS + [
        "pm.test('fact_session still has it', () => pm.expect(rows.length).to.equal(1));"],
        body=sql("SELECT session_id FROM fact_session WHERE session_id = '{{sessionId}}'")),
]

g5 = [
    req("Write: register a player (goes to the primary)", "POST", "{{gatewayUrl}}/auth/register",
        ["pm.test('201: the write was accepted', () => pm.response.to.have.status(201));",
         "pm.collectionVariables.set('replicatedId', pm.response.json().id);"],
        body={"username": "{{replicatedUser}}", "password": "{{password}}"},
        pre=["pm.collectionVariables.set('replicatedUser', 'lab5_repl_' + Date.now());",
             "pm.collectionVariables.set('tries', 0);"],
        desc="The Player Service has all three database nodes in its URL and keeps the one that accepts writes."),
    req("Read it back through the service", "GET", "{{gatewayUrl}}/players/{{replicatedId}}",
        ["pm.test('200: the player is there', () => pm.response.to.have.status(200));",
         "pm.test('same username', () => pm.expect(pm.response.json().username).to.equal(pm.collectionVariables.get('replicatedUser')));"],
        headers=AUTH),
    req("Replicated: the row is on a replica (the ETL job reads replicas)", "POST", DW, ROWS + WAIT + [
        "pm.test('the player came out of a replica into the warehouse', () => pm.expect(rows.length).to.equal(1));"],
        body=sql("SELECT player_id FROM dim_player WHERE player_id = {{replicatedId}}"),
        desc="The ETL job connects with target_session_attrs=prefer-standby, so what it loads was read from a replica: the write made on the primary was streamed there."),
    req("Write to the Game database too: create a session", "POST", "{{gatewayUrl}}/game/sessions",
        ["pm.test('201: the write was accepted', () => pm.response.to.have.status(201));",
         "pm.collectionVariables.set('sessionId', pm.response.json().id);"],
        body={"name": "lab5 replication", "host_player_id": "{{playerId}}"}, headers=AUTH),
    req("Read it back, then clean up", "DELETE", "{{gatewayUrl}}/game/sessions/{{sessionId}}",
        ["pm.test('204: found and deleted', () => pm.response.to.have.status(204));"], headers=AUTH,
        desc="Failover: `docker stop in-kahoots-with-the-undead-player-db-0-1` (or Test-Failover in lab5-tests.ps1), wait about 30 s, run this folder again: every request still passes, on the promoted node."),
]

FOLDER_AUTH = {"Authorization": "Bearer {{cacheToken}}"}
CACHED = "{{gatewayUrl}}/players/{{cachedId}}"

g6 = [
    req("A fresh player for this folder", "POST", "{{gatewayUrl}}/auth/register",
        ["pm.test('201: the player is created', () => pm.response.to.have.status(201));",
         "pm.collectionVariables.set('cachedId', pm.response.json().id);"],
        body={"username": "{{cachedUser}}", "password": "{{password}}"},
        pre=["pm.collectionVariables.set('cachedUser', 'lab5_cache_' + Date.now());"],
        desc="Nobody has asked for this player yet, so the first GET below is certainly not in the cache."),
    req("GET a player the first time: MISS, the Player Service answers", "GET", CACHED,
        ["pm.test('200', () => pm.response.to.have.status(200));",
         "pm.test('X-Cache: MISS', () => pm.expect(pm.response.headers.get('X-Cache')).to.equal('MISS'));",
         "pm.test('X-Cache-Node names the Redis node the key lives on', () => pm.expect(pm.response.headers.get('X-Cache-Node')).to.match(/^cache-[0-9]+$/));",
         "pm.collectionVariables.set('cachedNode', pm.response.headers.get('X-Cache-Node'));",
         "pm.collectionVariables.set('cachedBody', pm.response.text());"], headers=AUTH),
    req("GET it again: HIT, answered by the gateway from Redis", "GET", CACHED,
        ["pm.test('200', () => pm.response.to.have.status(200));",
         "pm.test('X-Cache: HIT', () => pm.expect(pm.response.headers.get('X-Cache')).to.equal('HIT'));",
         "pm.test('from the same node as before', () => pm.expect(pm.response.headers.get('X-Cache-Node')).to.equal(pm.collectionVariables.get('cachedNode')));",
         "pm.test('the same body the service gave', () => pm.expect(pm.response.text()).to.equal(pm.collectionVariables.get('cachedBody')));"],
        headers=AUTH, desc="The request never reached the broker or the Player Service: the gateway log says `-> cache at cache-N`."),
    req("Change the player: the cached answer is dropped", "PUT", CACHED,
        ["pm.test('200: updated', () => pm.response.to.have.status(200));"],
        body={"username": "{{cachedUser}}", "display_name": "Changed"}, headers=AUTH),
    req("GET after the change: MISS, and the new value", "GET", CACHED,
        ["pm.test('X-Cache: MISS (the change removed the key)', () => pm.expect(pm.response.headers.get('X-Cache')).to.equal('MISS'));",
         "pm.test('the new display name, not the cached one', () => pm.expect(pm.response.json().display_name).to.equal('Changed'));"],
        headers=AUTH),
    req("The item catalog is cached too (asked twice: the second is a HIT)", "GET", "{{gatewayUrl}}/players/items",
        ["const asked = Number(pm.collectionVariables.get('tries') || 0);",
         "if (asked === 0) { pm.collectionVariables.set('tries', 1); postman.setNextRequest(pm.info.requestName); return; }",
         "pm.collectionVariables.set('tries', 0);",
         "pm.test('200', () => pm.response.to.have.status(200));",
         "pm.test('X-Cache: HIT', () => pm.expect(pm.response.headers.get('X-Cache')).to.equal('HIT'));"],
        headers=AUTH, pre=["if (!pm.collectionVariables.get('tries')) pm.collectionVariables.set('tries', 0);"]),
    req("A route that is not on the list is never cached", "GET", "{{gatewayUrl}}/game/sessions",
        ["pm.test('200', () => pm.response.to.have.status(200));",
         "pm.test('no X-Cache header', () => pm.expect(pm.response.headers.has('X-Cache')).to.equal(false));"],
        headers=AUTH, desc="Only the GET routes in the gateway's CACHED_GETS list are cached: the ones whose answer is the same for every player."),
    req("Log in: a new token", "POST", "{{gatewayUrl}}/auth/login",
        ["pm.test('200 and a token', () => pm.response.to.have.status(200));",
         "pm.collectionVariables.set('cacheToken', pm.response.json().access_token);"],
        body={"username": "{{cachedUser}}", "password": "{{password}}"}),
    req("Authentication data: the first request with a token verifies its signature (MISS)", "GET", "{{gatewayUrl}}/game/sessions",
        ["pm.test('200', () => pm.response.to.have.status(200));",
         "pm.test('X-Auth-Cache: MISS', () => pm.expect(pm.response.headers.get('X-Auth-Cache')).to.equal('MISS'));"],
        headers=FOLDER_AUTH),
    req("The next request with it: the player id comes from Redis (HIT)", "GET", "{{gatewayUrl}}/game/sessions",
        ["pm.test('200', () => pm.response.to.have.status(200));",
         "pm.test('X-Auth-Cache: HIT', () => pm.expect(pm.response.headers.get('X-Auth-Cache')).to.equal('HIT'));"],
        headers=FOLDER_AUTH, desc="The key is auth:<SHA-256 of the token>, the value the player id. The token itself is never stored."),
    req("Logout needs a real token", "POST", "{{gatewayUrl}}/auth/logout",
        ["pm.test('401 for a token nobody issued', () => pm.response.to.have.status(401));"],
        headers={"Authorization": "Bearer not-a-token"}),
    req("Log out: the token is revoked in the cache", "POST", "{{gatewayUrl}}/auth/logout",
        ["pm.test('200', () => pm.response.to.have.status(200));",
         "pm.test('logged_out', () => pm.expect(pm.response.json().status).to.equal('logged_out'));"],
        headers=FOLDER_AUTH, desc="A JWT cannot be taken back by the service that issued it. The gateway remembers it as revoked until it would have expired."),
    req("The logged out token is refused, although its signature is still valid", "GET", "{{gatewayUrl}}/game/sessions",
        ["pm.test('401', () => pm.response.to.have.status(401));",
         "pm.test('the reason is the logout', () => pm.expect(pm.response.json().error.message).to.include('logged out'));"],
        headers=FOLDER_AUTH),
    req("Another token of the same player still works", "GET", "{{gatewayUrl}}/game/sessions",
        ["pm.test('200: only the logged out token is refused', () => pm.response.to.have.status(200));"],
        headers=AUTH),
]

g7 = [
    req("30 keys are spread over the three nodes", "GET", "{{gatewayUrl}}/players/{{ringId}}",
        ["const nodes = JSON.parse(pm.collectionVariables.get('ringNodes') || '{}');",
         "const node = pm.response.headers.get('X-Cache-Node');",
         "nodes[node] = (nodes[node] || 0) + 1;",
         "pm.collectionVariables.set('ringNodes', JSON.stringify(nodes));",
         "const id = Number(pm.collectionVariables.get('ringId'));",
         "if (id < 30) { pm.collectionVariables.set('ringId', id + 1); postman.setNextRequest(pm.info.requestName); return; }",
         "pm.collectionVariables.set('ringId', '');",
         "console.log('keys per node:', JSON.stringify(nodes));",
         "pm.test('every key names its node', () => pm.expect(Object.keys(nodes).every(n => /^cache-[0-9]+$/.test(n))).to.equal(true));",
         "pm.test('all three nodes hold keys: ' + JSON.stringify(nodes), () => pm.expect(Object.keys(nodes).length).to.equal(3));"],
        headers=AUTH,
        pre=["if (!pm.collectionVariables.get('ringId')) {",
             "    pm.collectionVariables.set('ringId', 1);",
             "    pm.collectionVariables.set('ringNodes', '{}');",
             "}"],
        desc="Asks for /players/1 ... /players/30 (whether they exist does not matter) and counts the X-Cache-Node of each: the node the gateway's hash ring picked for the key get:/players/<n>."),
    req("The same key always goes to the same node", "GET", "{{gatewayUrl}}/players/7",
        ["const node = pm.response.headers.get('X-Cache-Node');",
         "const first = pm.collectionVariables.get('sameNode');",
         "if (!first) { pm.collectionVariables.set('sameNode', node); postman.setNextRequest(pm.info.requestName); return; }",
         "pm.collectionVariables.set('sameNode', '');",
         "pm.test('asked twice, the same node: ' + node, () => pm.expect(node).to.equal(first));"],
        headers=AUTH, pre=["if (pm.collectionVariables.get('sameNode') === undefined) pm.collectionVariables.set('sameNode', '');"],
        desc="The node is computed from the key alone (MD5 of the key, first ring point clockwise), so nothing has to be remembered about where a key is."),
    req("Different keys of one player may live on different nodes", "GET", "{{gatewayUrl}}/players/7/inventory",
        ["pm.test('the inventory key has its own place on the ring', () => pm.expect(pm.response.headers.get('X-Cache-Node')).to.match(/^cache-[0-9]+$/));"],
        headers=AUTH,
        desc="A node going down, a node being added, and ring against `hash % N`: Test-CacheNodeDown and Show-HashRing in lab5-tests.ps1."),
]

KEY = {"X-Internal-Key": "{{internalKey}}"}
JOIN = "{{gatewayUrl}}/game/sessions/{{txSessionId}}/players"
LAST_TX = ["const tx = pm.response.json().transactions[0];"]

g8 = [
    req("A player who will join", "POST", "{{gatewayUrl}}/auth/register",
        ["pm.test('201', () => pm.response.to.have.status(201));",
         "pm.collectionVariables.set('joinerId', pm.response.json().id);"],
        body={"username": "{{joinerUser}}", "password": "{{password}}"},
        pre=["pm.collectionVariables.set('joinerUser', 'lab5_join_' + Date.now());"]),
    req("A session to join", "POST", "{{gatewayUrl}}/game/sessions",
        ["pm.test('201', () => pm.response.to.have.status(201));",
         "pm.collectionVariables.set('txSessionId', pm.response.json().id);"],
        body={"name": "lab5 two phase commit", "host_player_id": "{{playerId}}"}, headers=AUTH),
    req("Join: one request, two databases, committed in both", "POST", JOIN,
        ["pm.test('201: joined', () => pm.response.to.have.status(201));",
         "pm.test('the member the Game Service prepared', () => pm.expect(pm.response.json().player_id).to.equal(Number(pm.collectionVariables.get('joinerId'))));"],
        body={"player_id": "{{joinerId}}"}, headers=AUTH,
        desc="The broker does not forward this request. It asks Player to PREPARE the online flag and Game to PREPARE the member row, stores its decision, then tells both to COMMIT."),
    req("The coordinator's record: committed, participants player and game", "GET", "{{brokerUrl}}/transactions",
        LAST_TX + ["pm.test('200', () => pm.response.to.have.status(200));",
                   "pm.test('state committed', () => pm.expect(tx.state).to.equal('committed'));",
                   "pm.test('participants: player, game', () => pm.expect(tx.participants).to.eql(['player', 'game']));"],
        headers=KEY),
    req("The Player half happened: the joiner is online", "GET", "{{gatewayUrl}}/players/{{joinerId}}",
        ["pm.test('is_online is true', () => pm.expect(pm.response.json().is_online).to.equal(true));"],
        headers=AUTH, desc="Before Lab 5 the Game Service set this flag from a goroutine after answering, and did not care whether it landed."),
    req("Game votes no (already a member): 409, nothing committed", "POST", JOIN,
        ["pm.test('409, the answer of the Game Service', () => pm.response.to.have.status(409));",
         "pm.test('says why', () => pm.expect(pm.response.json().error).to.include('already a member'));"],
        body={"player_id": "{{joinerId}}"}, headers=AUTH),
    req("The coordinator's record: aborted, because game voted no", "GET", "{{brokerUrl}}/transactions",
        LAST_TX + ["pm.test('state aborted', () => pm.expect(tx.state).to.equal('aborted'));",
                   "pm.test('game voted no: 409', () => pm.expect(tx.detail).to.equal('game voted no: 409'));"],
        headers=KEY),
    req("A player who was never online", "POST", "{{gatewayUrl}}/auth/register",
        ["pm.test('201', () => pm.response.to.have.status(201));",
         "pm.collectionVariables.set('offlineId', pm.response.json().id);"],
        body={"username": "{{offlineUser}}", "password": "{{password}}"},
        pre=["pm.collectionVariables.set('offlineUser', 'lab5_off_' + Date.now());"]),
    req("Player votes yes, Game votes no (no such session): 404", "POST",
        "{{gatewayUrl}}/game/sessions/00000000-0000-4000-8000-000000000000/players",
        ["pm.test('404 from the Game Service', () => pm.response.to.have.status(404));"],
        body={"player_id": "{{offlineId}}"}, headers=AUTH,
        desc="Player had already prepared online=true for this player when Game said no. The coordinator tells Player to ROLLBACK PREPARED."),
    req("Atomic: the Player half was rolled back, the player is still offline", "GET", "{{gatewayUrl}}/players/{{offlineId}}",
        ["pm.test('is_online is false', () => pm.expect(pm.response.json().is_online).to.equal(false));"],
        headers=AUTH),
    req("Player votes no (unknown player): 422, Game is never asked", "POST", JOIN,
        ["pm.test('422', () => pm.response.to.have.status(422));",
         "pm.test('unknown player', () => pm.expect(pm.response.json().error).to.include('unknown player'));"],
        body={"player_id": 999999999}, headers=AUTH),
    req("The coordinator's record: aborted, because player voted no", "GET", "{{brokerUrl}}/transactions",
        LAST_TX + ["pm.test('player voted no: 422', () => pm.expect(tx.detail).to.equal('player voted no: 422'));"],
        headers=KEY),
    req("The transaction list needs the internal key", "GET", "{{brokerUrl}}/transactions",
        ["pm.test('401 without the key', () => pm.response.to.have.status(401));"]),
    req("The participants' endpoints are closed on the gateway", "POST",
        "{{gatewayUrl}}/game/internal/tx/00000000-0000-4000-8000-000000000000/commit",
        ["pm.test('404: players cannot commit or roll back anything', () => pm.response.to.have.status(404));"],
        headers=AUTH),
    req("Clean up: delete the session", "DELETE", "{{gatewayUrl}}/game/sessions/{{txSessionId}}",
        ["pm.test('204', () => pm.response.to.have.status(204));"], headers=AUTH,
        desc="The broker stopped between the decision and the commit: Test-TwoPhaseCrash in lab5-tests.ps1."),
]

collection = {
    "info": {
        "name": "Lab 5: defence",
        "description": "One folder per grade, against the whole stack (docker compose up -d). Run folder 0 first: it creates the player and token the others use. After it, each folder runs on its own.",
        "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
    },
    "variable": [{"key": k, "value": v} for k, v in [
        ("gatewayUrl", "http://localhost:8080"), ("grafanaUrl", "http://localhost:3001"),
        ("password", "hunter2hunter2"), ("user", ""), ("playerId", ""), ("token", ""),
        ("sessionId", ""), ("replicatedUser", ""), ("replicatedId", ""), ("tries", "0"),
        ("cachedUser", ""), ("cachedId", ""), ("cachedNode", ""), ("cachedBody", ""), ("cacheToken", ""),
        ("ringId", ""), ("ringNodes", "{}"), ("sameNode", ""),
        ("brokerUrl", "http://localhost:8070"), ("internalKey", "changeme"),
        ("joinerUser", ""), ("joinerId", ""), ("txSessionId", ""), ("offlineUser", ""), ("offlineId", "")]],
    "item": [
        {"name": "0. Setup: a player and a token", "item": setup},
        {"name": "Grade 4: Data Warehouse and ETL", "item": g4},
        {"name": "Grade 5: database replication and failover", "item": g5},
        {"name": "Grade 6: cache for common GET requests and for authentication data", "item": g6},
        {"name": "Grade 7: cache sharding by consistent hashing", "item": g7},
        {"name": "Grade 8: two phase commit for joining a session", "item": g8},
    ],
}

with open(OUT, "w", encoding="utf-8", newline="\n") as f:
    f.write(json.dumps(collection, indent=2, ensure_ascii=False) + "\n")
