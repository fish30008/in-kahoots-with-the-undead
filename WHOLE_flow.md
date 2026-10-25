# Whole flow: Lab 3, Scaling Up

How the system finds, balances, protects and watches several copies of each
service. It covers the core logic of every part added in Lab 3, with the code
that implements it. Snippets are taken from the services as they are on `main`;
`...` marks a cut.

- [1. The picture](#1-the-picture)
- [2. Where each grade lives](#2-where-each-grade-lives)
- [3. The life of one instance](#3-the-life-of-one-instance)
- [4. Service Discovery](#4-service-discovery)
- [5. Registering: Player, Game, Gateway](#5-registering-player-game-gateway)
- [6. The Gateway: registry and round robin](#6-the-gateway-registry-and-round-robin)
- [7. Running several copies in Compose](#7-running-several-copies-in-compose)
- [8. Making Game instance-agnostic](#8-making-game-instance-agnostic)
- [9. Circuit breaker](#9-circuit-breaker)
- [10. Health checks and load](#10-health-checks-and-load)
- [11. Telegram alerts](#11-telegram-alerts)
- [12. Removal and coming back](#12-removal-and-coming-back)
- [13. Three requests, end to end](#13-three-requests-end-to-end)
- [14. Configuration](#14-configuration)
- [15. Known limits](#15-known-limits)

---

## 1. The picture

```
                         browser
              REST │                 │ WebSocket (direct)
                   ▼                 ▼
             ┌──────────┐      game :8082 / game-2 :8083
             │ Gateway  │
             │  :8080   │── round robin ──► player-1, player-2      (Go)
             └──────────┘── round robin ──► game, game-2            (Go)
               │     ▲   └─ fixed URL ───► exam, world, zombie, ... (teammates)
  GET /services│     │register / deregister
   every 5 s   ▼     │
             ┌──────────────┐   GET /health every 10 s   ┌──────────────────┐
             │  Discovery   │──────────────────────────► │ every registered │
             │    :8090     │                            │    instance      │
             └──────────────┘                            └──────────────────┘
                     │ ALERT / RESOLVED
                     ▼
                  Telegram

  every instance ──POST /register every 15 s──► Discovery
  game ◄──── Postgres NOTIFY "game_events" ────► game-2      (shared game-db)
```

The three rules from earlier labs still hold, and Lab 3 is built around them:

1. **One door.** All REST goes through the Gateway, including calls between
   services. So only the Gateway needs to know where the copies of a service are,
   and only the Gateway balances.
2. **Credentials stop at the door.** Services trust `X-Internal-Key` from each
   other; the discovery service checks the same key.
3. **One database per service.** Copies of a service share *its* database
   (`player-1` and `player-2` both use `player-db`), never another service's.

What Lab 3 adds:

- **Discovery** holds the list of running copies.
- **Services announce themselves** to it, and keep doing so.
- **The Gateway reads the list** and takes the copies in turn.
- **A circuit breaker** removes what keeps failing.
- **Discovery checks everyone's health** and messages the developers on Telegram.

---

## 2. Where each grade lives

| Grade | Requirement | Implementation |
| --- | --- | --- |
| 2 | Discovery repo, README, CI | `services/service_discovery`, `.github/workflows/docker-publish.yml` |
| 3 | Status endpoint, logs | `GET /health` everywhere ([§10](#10-health-checks-and-load)); log lines in every part below |
| 4 | Discovery with a register endpoint, on Docker Hub | `service_discovery/app/main.py` ([§4](#4-service-discovery)), `fish3008/service_discovery` |
| 5 | 2–3 copies, added and removed dynamically | `compose.yml` ([§7](#7-running-several-copies-in-compose)), registration ([§5](#5-registering-player-game-gateway)), Gateway refresh ([§6](#6-the-gateway-registry-and-round-robin)) |
| 6 | Round-robin load balancer, instance-agnostic logic | `gateway_service/app/discovery.py` `pick()` ([§6](#6-the-gateway-registry-and-round-robin)); Game hub, clock lock, migration lock ([§8](#8-making-game-instance-agnostic)) |
| 7 | Circuit breaker that logs | `gateway_service/app/breaker.py`, `game_service/internal/breaker` ([§9](#9-circuit-breaker)) |
| 8 | Discovery polls health, alerts on critical load | `check()` / `check_all()` in discovery, load on `/health` ([§10](#10-health-checks-and-load)) |
| 9 | Alerts to Telegram, Discord or e-mail | `notify()` in discovery ([§11](#11-telegram-alerts)) |
| 10 | Circuit breaker that removes | `discovery.remove()` in the Gateway, `removedUntil` in Game ([§9](#9-circuit-breaker), [§12](#12-removal-and-coming-back)) |

---

## 3. The life of one instance

Take `player-2`, the second Player container:

```
 start ──► builds its own URL from its hostname: http://93eb690089c6:8081
   │
   ├──► POST /register {"name":"player","url":"http://93eb690089c6:8081"}  ──► Discovery
   │        (retries every 5 s until accepted)
   │
   │    within 5 s the Gateway reads GET /services and adds it to the rotation
   │
   ├──► every 15 s:  POST /register again      (renewal, logged only on a change)
   ├──◄ every 10 s:  GET /health from Discovery (load: in_flight, max, refused)
   ├──◄ requests from the Gateway, its turn every other request
   │
   ├─ if 3 forwards to it fail within 105 s ──► Gateway removes it  (§9)
   │        still alive?  its next renewal puts it back within 15 s
   │        dead?         nothing renews it, it stays out
   │
 stop (SIGTERM) ──► POST /deregister ──► gone from the list before the server closes
```

---

## 4. Service Discovery

`services/service_discovery/app/main.py`: one FastAPI file with no database. The
list lives in memory, in a dict:

```python
# service name -> base URLs of its running instances. Kept in memory only, so the
# registry is empty after a restart until the services register again. The handlers
# are `async def` on purpose: they all run on the one event loop, so no lock is needed.
registry: dict[str, list[str]] = {}
```

Because every handler is `async def` and none of them awaits while changing the
dict, they never run interleaved, so no lock is needed. For the same reason the
service runs as **one** process: a second worker would hold a different dict.

### Endpoints

| Method | Path | Body | What it does |
| --- | --- | --- | --- |
| `POST` | `/register` | `{"name", "url"}` | adds the instance; a repeat is a no-op |
| `POST` | `/deregister` | `{"name", "url"}` | removes it; `404` if unknown |
| `GET` | `/services` | | `{"player": [...], "game": [...], ...}` |
| `GET` | `/health` | | always open |

Everything except `/health` needs `X-Internal-Key`:

```python
def require_key(x_internal_key: str = Header(default="")) -> None:
    if not secrets.compare_digest(x_internal_key.encode(), INTERNAL_KEY.encode()):
        raise HTTPException(401, "missing or wrong X-Internal-Key")
```

Registering is safe to repeat. That property is what makes renewal ([§5](#5-registering-player-game-gateway)) work:

```python
@app.post("/register", dependencies=[Depends(require_key)])
async def register(instance: Instance) -> dict[str, str]:
    # a path is appended to the URL by plain concatenation
    url = instance.url.rstrip("/")
    urls = registry.setdefault(instance.name, [])
    if url in urls:
        # routine renewal, every few seconds per instance
        log.debug("%s at %s registered again, already known", instance.name, url)
    else:
        urls.append(url)
        log.info("registered %s at %s (%d instance(s) now)", instance.name, url, len(urls))
    return {"name": instance.name, "url": url}
```

Input is validated by Pydantic: `name` must not be empty, and `url` must start
with `http://` or `https://` (otherwise `422`).

### What is in the registry

```json
{
  "player":      ["http://41f0f430470b:8081", "http://93eb690089c6:8081"],
  "game":        ["http://cce1ce99fcf2:8082", "http://73078ae3edc6:8082"],
  "game-public": ["http://localhost:8082", "http://localhost:8083"],
  "gateway":     ["http://f6fb9ac8a1b2:8080"]
}
```

- `player`, `game`: internal addresses, used by the Gateway to forward REST.
- `game-public`: where a **browser** reaches each Game copy for its WebSocket ([§8](#8-making-game-instance-agnostic)).
- `gateway`: the Gateway registers itself so its health is checked too.

The teammates' services do not register. The Gateway reaches them at their fixed
URLs, as before.

---

## 5. Registering: Player, Game, Gateway

### Each copy knows its own address

Every copy runs from the same image with the same environment, so nobody can
tell it its URL. It builds it from its hostname, which inside Docker is the
container's id and resolves on the compose network
(`player_service/internal/config/config.go`, same in Game):

```go
// Inside Docker the hostname is the container's own name on the network,
// so every copy of the service gets a different URL without being told one.
if cfg.ServiceURL == "" {
	host, err := os.Hostname()
	if err != nil {
		host = "localhost"
	}
	cfg.ServiceURL = "http://" + host + ":" + cfg.Port
}
```

All copies use the same port (`8081`). They differ by host, like two computers
each running a server on port 8081.

### Register, then keep renewing

`internal/discovery/discovery.go` is the same file in Player and Game:

```go
// retryEvery is the pause between attempts while the Service Discovery is not
// answering yet.
const retryEvery = 5 * time.Second

// renewEvery is the pause between two registrations once it answers.
const renewEvery = 15 * time.Second

func (i Instance) Register(ctx context.Context) {
	if i.DiscoveryURL == "" {
		log.Println("discovery: DISCOVERY_URL is not set, not registering")
		return
	}
	registered := false
	for {
		wait := renewEvery
		err := i.post(ctx, "/register")
		switch {
		case ctx.Err() != nil:
			return
		case err == nil && !registered:
			log.Printf("discovery: registered %s at %s with %s, renewed every %s", ...)
			registered = true
		case err != nil:
			... // logged once, then retried every 5 s
			registered = false
			wait = retryEvery
		}

		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
	}
}
```

Renewing every 15 s solves three problems:

- **A Discovery restart** empties the list; it is full again within 15 s.
- **A copy removed by the Gateway's breaker** that is actually alive comes back by itself ([§12](#12-removal-and-coming-back)).
- **A copy that dies without deregistering** stops renewing, and Discovery drops it after 45 s ([§12](#12-removal-and-coming-back)).

### Wiring in `main.go`

Game shown; Player is the same without `public`:

```go
// Announced once the server is starting, so the Gateway can route here.
self := discovery.Instance{
	DiscoveryURL: cfg.DiscoveryURL,
	InternalKey:  cfg.InternalKey,
	Name:         "game",
	URL:          cfg.ServiceURL,
}
go self.Register(ctx)
...
<-ctx.Done()
log.Println("shutting down")

// Removed first, so the Gateway stops sending requests before the server closes.
self.Deregister()
```

`ctx` is cancelled by SIGTERM/SIGINT (`signal.NotifyContext`), which is what
`docker stop` sends. `docker kill` sends SIGKILL instead: no deregistration, which
is exactly the case the circuit breaker exists for.

### The Gateway registers itself

`gateway_service/app/discovery.py`, every round of its refresh loop:

```python
SELF = {"name": "gateway", "url": f"http://{socket.gethostname()}:{settings.port}"}

async def watch(client: httpx.AsyncClient) -> None:
    registered: bool | None = None
    while True:
        ok = await post(client, "/register", SELF)
        if ok != registered:
            ... # log "registered" or "could not register", only on a change
            registered = ok
        await asyncio.sleep(settings.discovery_refresh)
        await refresh(client)
```

---

## 6. The Gateway: registry and round robin

### Reading the list

On startup the Gateway reads the registry once before serving, then every
`DISCOVERY_REFRESH` seconds (5). If Discovery cannot be read, the last list stays
in use, so a Discovery outage does not take routing down:

```python
async def refresh(client: httpx.AsyncClient) -> None:
    """Read the registry once. On failure the last known list stays in use."""
    try:
        response = await client.get(settings.discovery_url + "/services",
                                    headers={"x-internal-key": settings.internal_key},
                                    timeout=READ_TIMEOUT)
        response.raise_for_status()
        latest: dict[str, list[str]] = response.json()
    except (httpx.HTTPError, ValueError) as exc:
        log.warning("service discovery at %s not read (%r), keeping the last list", ...)
        return

    for service in sorted(set(instances) | set(latest)):
        ... # logs "player instance added: ... (2 now)" / "removed: ... (1 left)"
    instances.clear()
    instances.update(latest)
```

### Round robin

Each service has a counter. The instance whose turn it is equals the counter
modulo the number of instances:

```python
# service name -> base URLs of its running instances, as last read from the Service Discovery
instances: dict[str, list[str]] = {}
# service name -> how many requests it has been given, which is whose turn it is
turns: defaultdict[str, count] = defaultdict(count)


def pick(service: str) -> str:
    """The instance that takes the next request: each one in turn (round robin).

    A service with no registered instance, such as one that does not register at all, is
    reached at its fixed URL from the configuration.
    """
    urls = instances.get(service)
    if not urls:
        return SERVICES[service]
    return urls[next(turns[service]) % len(urls)]
```

With `[A, B]` the requests go `A, B, A, B, ...`. With a third copy the same code
gives `A, B, C, A, ...`. There is no Redis and no shared state: it is one counter
in the Gateway's memory.

### Forwarding

`app/routers/proxy.py`. The first path segment picks the service (`/auth`,
`/players`, `/trades` → `player`, `/game` → `game`), then `pick()` picks the copy:

```python
    # the instance whose turn it is, when the service runs as several
    base_url = pick(service)
    log.info("%s /%s received from %s (%s), forwarding to %s at %s", ...)
    started = time.perf_counter()
    try:
        response = await forward_http(request.app.state.http, base_url, request, caller)
    except asyncio.CancelledError:
        # the gateway's own time limit ran out while the service was still working
        breaker.failure(service, base_url, f"no answer within {settings.task_timeout:g}s")
        raise
    # unreachable, timed out (503, 504 from forward_http) or failing on its side
    if response.status_code >= 500:
        breaker.failure(service, base_url, f"status {response.status_code}")
    log.info("%s /%s forwarded to %s at %s: %s in %.0f ms, %d bytes transmitted", ...)
    return response
```

The log line names the instance, which is how round robin is seen:

```
POST /auth/login forwarded to player at http://91d02c41e29c:8081: 401 in 25 ms
POST /auth/login forwarded to player at http://7e9d68bf6116:8081: 401 in 11 ms
POST /auth/login forwarded to player at http://91e78723ebd3:8081: 401 in 9 ms
POST /auth/login forwarded to player at http://91d02c41e29c:8081: 401 in 5 ms
```

`pick()` is also used when another service asks the Gateway where a producer's
event stream is (`GET /ws/player` → `ws://<a player copy>/events`), so those
requests take a turn in the same rotation.

---

## 7. Running several copies in Compose

### Player: `replicas`

```yaml
  player:
    image: ${DOCKERHUB_USERNAME:-fish3008}/player_service:${PLAYER_SERVICE_TAG:-2}
    environment:
      PORT: ${PLAYER_PORT:-8081}
      ...
      DISCOVERY_URL: http://discovery:8090
    # Several copies, so no port is published: they cannot share one on the host.
    # Every request reaches them through the gateway, which takes them in turn.
    deploy:
      replicas: ${PLAYER_REPLICAS:-2}
    depends_on:
      player-db:
        condition: service_healthy
      discovery:
        condition: service_healthy
```

- **No `ports:`.** A host port can belong to one container only, so `localhost:8081` no longer exists. The copies are reached only through the Gateway.
- **Scaling while running:** `docker compose ... up -d --scale player=3 --no-recreate`. The new copy registers, and the Gateway logs `player instance added ... (3 now)` within 5 s.

### Game: two declared services

The browser connects to a Game copy **directly** for its WebSocket, so each copy
needs its own host port. That is why Game uses two services, with a YAML anchor
so `game-2` copies everything from `game` except its port and public address:

```yaml
  game: &game
    image: ${DOCKERHUB_USERNAME:-fish3008}/game_service:${GAME_SERVICE_TAG:-2}
    environment: &game-env
      PORT: ${GAME_PORT:-8082}
      ...
      DISCOVERY_URL: http://discovery:8090
      PUBLIC_URL: http://localhost:${GAME_PORT:-8082}
    ports:
      - "${GAME_PORT:-8082}:${GAME_PORT:-8082}"

  game-2:
    <<: *game
    environment:
      <<: *game-env
      PUBLIC_URL: http://localhost:${GAME_2_PORT:-8083}
    ports:
      - "${GAME_2_PORT:-8083}:${GAME_PORT:-8082}"
```

Both copies use the same `game-db`.

### Startup order

`discovery` has a healthcheck, and Player and Game wait for it to be healthy, so
their first registration usually succeeds. If it does not, they retry every 5 s.

---

## 8. Making Game instance-agnostic

Player keeps all its state in Postgres, so any copy can answer any request.
Game did not, which is the second half of grade 6. Reading its engine and hub
showed two real problems with two copies.

| Problem | Why | Fix |
| --- | --- | --- |
| A watcher misses events | The hub keeps WebSockets in memory, per copy. An event raised on `game-2` (by its engine or a REST handler) only reached sockets on `game-2`. | Events go through Postgres `NOTIFY`; every copy `LISTEN`s and delivers to its own sockets. |
| Zombies spawn twice | `spawnZombies` reads "nights without zombies" and then inserts, so two engines could both insert. | Only one copy runs the clock, chosen by a Postgres advisory lock. |
| Migrations collide | Two copies starting on an empty database both run `CREATE TABLE IF NOT EXISTS`, which can still fail when concurrent. | The schema runs behind an advisory lock (Player too). |

The other engine jobs were already safe. They claim work with a single
`UPDATE ... RETURNING`, so each row goes to exactly one copy.

### Events through Postgres

`game_service/internal/hub/hub.go`. `Broadcast` no longer writes to sockets; it
hands the event to Postgres:

```go
// channel is the Postgres NOTIFY channel every instance listens on.
const channel = "game_events"

// Broadcast sends one event to every watcher of a session, on every instance.
func (h *Hub) Broadcast(sessionID uuid.UUID, eventType string, data any) {
	payload, ok := encode(sessionID, eventType, data)
	if !ok {
		return
	}
	if len(payload) > maxNotify {
		... // over Postgres' 8000-byte limit: this instance's watchers only
		h.deliver(sessionID, payload)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), notifyTimeout)
	defer cancel()
	if _, err := h.pool.Exec(ctx, "SELECT pg_notify($1, $2)", channel, string(payload)); err != nil {
		// Postgres did not take it, so at least the watchers here hear it.
		log.Printf("hub: notify %s event for session %s: %v: ...", eventType, sessionID, err)
		h.deliver(sessionID, payload)
	}
}
```

Every copy listens on one dedicated connection and delivers what arrives to the
sockets it holds:

```go
func (h *Hub) listen(ctx context.Context) error {
	c, err := h.pool.Acquire(ctx)
	if err != nil {
		return err
	}
	// LISTEN belongs to one connection, so it is taken out of the pool for good.
	conn := c.Hijack()
	defer conn.Close(context.Background())

	if _, err := conn.Exec(ctx, "LISTEN "+channel); err != nil {
		return err
	}
	log.Printf("hub: listening for events of every instance on %q", channel)

	for {
		n, err := conn.WaitForNotification(ctx)
		if err != nil {
			return err
		}
		var event Event
		if err := json.Unmarshal([]byte(n.Payload), &event); err != nil { ... }
		h.deliver(event.SessionID, []byte(n.Payload))
	}
}
```

`Listen` wraps this in a retry loop (every 2 s) in case the connection breaks.
Progress frames are the exception: every copy computes them each tick for its
own watchers, so they use `BroadcastLocal` and skip Postgres.

This uses the database Game already has, so there is no broker. It also matches
how the services already publish events (an outbox in Postgres).

### One clock, chosen by a lock

`game_service/internal/engine/engine.go`. Every copy ticks, but only the holder
of advisory lock `7001` changes the game:

```go
func (e *Engine) tick(ctx context.Context) {
	// Progress frames go to the watchers connected here and change nothing, so
	// every instance sends them.
	e.broadcastProgress(ctx)

	// Everything else changes the game, so only the instance holding the lock does it.
	if !e.leading(ctx) {
		return
	}
	e.advancePhases(ctx)
	e.spawnZombies(ctx)
	e.completeActions(ctx)
	e.resolveAttacks(ctx)
	e.expireZombies(ctx)
}
```

```go
func (e *Engine) holdLock(ctx context.Context) bool {
	if e.lockConn != nil {
		// Already holding it: only check the connection, and with it the lock, is alive.
		if err := e.lockConn.Ping(ctx); err == nil {
			return true
		}
		... // connection lost: drop it and try to take the lock again below
	}

	c, err := e.pool.Acquire(ctx)
	...
	var got bool
	if err := c.QueryRow(ctx, "SELECT pg_try_advisory_lock($1)", clockLock).Scan(&got); err != nil { ... }
	if !got {
		c.Release()
		return false
	}
	e.lockConn = c.Hijack()
	return true
}
```

- **The lock belongs to a connection,** which is why that connection is taken out of the pool (`Hijack`) and kept.
- **Failover is automatic.** When the leader dies, its connection closes, Postgres frees the lock, and the other copy takes it on its next tick. Tested: under a second.
- **The logs show the roles:** `engine: this instance now runs the game clock` on one copy, `another instance runs the game clock, this one only sends progress` on the other.

### Schema behind a lock

`internal/database/database.go`, in Player and Game:

```go
func Migrate(ctx context.Context, pool *pgxpool.Pool) error {
	schema, err := schemaFS.ReadFile("schema.sql")
	...
	batch := fmt.Sprintf("SELECT pg_advisory_xact_lock(%d);\n%s", migrateLock, schema)
	if _, err := pool.Exec(ctx, batch); err != nil {
		return fmt.Errorf("apply schema: %w", err)
	}
	return nil
}
```

Statements sent as one batch run as one transaction, so the transaction-level
lock is held until the whole schema is applied, and then freed by itself.

### The browser's WebSocket

Each copy registers a second, public address
(`PUBLIC_URL=http://localhost:8082` / `8083`) under `game-public`. The Gateway hands
those out in turn (`app/routers/ws.py`):

```python
    if not caller.internal and service == "game":
        # the game client watching a session: a plain WebSocket, opened with
        # ?session_id=<id> added to the URL. Any Game instance serves any session,
        # so each client is handed the next one in turn.
        url = f"{to_ws(pick('game-public'))}/game"
        log.info("WebSocket for game handed to %s: %s", caller, url)
        return {"service": "game", "url": url, "protocol": "websocket"}
```

`GET /ws/game` answers `ws://localhost:8082/game`, then `8083`, then `8082`, and so
on. Thanks to `NOTIFY`, it does not matter which copy a player lands on. The
client did not have to change.

---

## 9. Circuit breaker

**The rule** (grades 7 and 10): a call fails when it gets no answer, runs out of
time, or answers `5xx`. Three failures within `TASK_TIMEOUT × 3.5` seconds (105 s
by default) trip the breaker. Then the failing service is **removed**.

It is implemented in each service that makes calls: the Gateway and Game. Player
and Discovery call no other service.

### In the Gateway: per instance

`gateway_service/app/breaker.py`:

```python
# failed calls to one instance that trip its breaker when they fall within WINDOW seconds
THRESHOLD = 3
WINDOW = settings.task_timeout * 3.5

# instance URL -> when its recent calls failed
failures: defaultdict[str, list[float]] = defaultdict(list)


def failure(service: str, url: str, reason: str) -> None:
    now = time.monotonic()
    recent = [at for at in failures[url] if now - at <= WINDOW]
    recent.append(now)
    log.warning("call to %s at %s failed (%s): %d of %d within %gs", ...)
    if len(recent) >= THRESHOLD:
        log.error("circuit breaker TRIPPED for %s at %s: %d failed calls within %gs, removing it", ...)
        discovery.remove(service, url)
        # counting starts again, so an instance that comes back and keeps failing trips again
        recent = []
    failures[url] = recent
```

It is called from the proxy for every `5xx` and for every request the Gateway
itself cancels at `TASK_TIMEOUT` ([§6](#6-the-gateway-registry-and-round-robin)),
so all endpoints count. Removal (`app/discovery.py`):

```python
def remove(service: str, url: str) -> None:
    """Take a failing instance out of rotation now, and out of the Service Discovery."""
    urls = instances.get(service, [])
    if url not in urls:
        log.warning("%s at %s is not a registered instance, so there is nothing to remove", ...)
        return
    urls.remove(url)
    log.warning("%s instance removed: %s (%d left), its circuit breaker tripped", ...)
    task = asyncio.create_task(deregister(service, url))
    pending.add(task)
    task.add_done_callback(pending.discard)
```

1. **Out of the local list:** the very next request already goes to a healthy copy.
2. **`POST /deregister` to Discovery:** it is gone for everyone, and the next refresh does not bring it back. This runs as a background task, because `failure()` can be called while the request is being cancelled.

What it looks like when a Player copy is killed (`docker kill`, so it never
deregistered). These are 10 logins in a row:

```
answers: 401 503 401 503 503 401 401 401 401 401

call to player at http://93eb690089c6:8081 failed (status 503): 1 of 3 within 105s
call to player at http://93eb690089c6:8081 failed (status 503): 2 of 3 within 105s
call to player at http://93eb690089c6:8081 failed (status 503): 3 of 3 within 105s
circuit breaker TRIPPED for player at http://93eb690089c6:8081: 3 failed calls within 105s, removing it
player instance removed: http://93eb690089c6:8081 (1 left), its circuit breaker tripped
player at http://93eb690089c6:8081 deregistered from the Service Discovery
```

### In Game: per target service

Every call Game makes goes to the Gateway, which picks the instance. So Game
cannot remove one instance; it removes the whole target, as seen from Game. The
breaker is an `http.RoundTripper`, set as the transport of each client (Player,
World, Exam), so it sees every call on every endpoint without touching the call
code (`game_service/internal/breaker/breaker.go`):

```go
func (b *Breaker) RoundTrip(req *http.Request) (*http.Response, error) {
	if until, removed := b.removed(); removed {
		// A RoundTripper must close the body even for a call it never sends.
		if req.Body != nil {
			req.Body.Close()
		}
		return nil, fmt.Errorf("%s is removed by its circuit breaker until %s", b.name, until.Format(time.TimeOnly))
	}

	resp, err := b.next.RoundTrip(req)
	switch {
	case errors.Is(err, context.Canceled):
		// This service gave up, for example on shutdown; the other side did nothing wrong.
	case err != nil:
		b.fail(req, err.Error())
	case resp.StatusCode >= 500:
		b.fail(req, resp.Status)
	}
	return resp, err
}
```

```go
	if len(recent) >= threshold {
		b.removedUntil = now.Add(b.window)
		log.Printf("breaker: TRIPPED for %s: %d failed calls within %s, removed until %s", ...)
		// Counting starts again, so a service that keeps failing trips again.
		recent = nil
	}
```

Plugged in where the clients are created (`cmd/api/main.go`):

```go
	breakerWindow := cfg.TaskTimeout * 7 / 2
	players := playerclient.New(cfg.PlayerServiceURL, cfg.InternalKey, breakerWindow)
	exams := examclient.New(cfg.ExamServiceURL, cfg.InternalKey, breakerWindow)
	rooms := worldclient.New(cfg.WorldServiceURL, cfg.InternalKey, breakerWindow)

// in playerclient.New:
	http: &http.Client{Transport: breaker.New("player service", breakerWindow)},
```

Once removed, calls fail in about 1 ms instead of each waiting for its timeout:

```
call 1 -> 502 in 1987 ms
call 2 -> 502 in 1935 ms
call 3 -> 502 in 1936 ms      breaker: TRIPPED for player service ... removed until 19:59:44
call 4 -> 502 in 2 ms
call 5 -> 502 in 1 ms
```

When the window ends, the next call goes out again (`breaker: player service is
back in use`).

---

## 10. Health checks and load

### Every service reports its load

The request limiter that already enforced `MAX_CONCURRENT_TASKS` now also counts
(`internal/api/limits.go`, Player and Game):

```go
// inFlight and refused are reported on /health so the Service Discovery can judge
// the load: requests being handled right now, and requests refused with 429 since
// the service started.
var inFlight, refused atomic.Int64

func Limit(max int) func(http.Handler) http.Handler {
	slots := make(chan struct{}, max)
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			select {
			case slots <- struct{}{}:
				inFlight.Add(1)
				defer func() {
					inFlight.Add(-1)
					<-slots
				}()
				next.ServeHTTP(w, r)
			default:
				refused.Add(1)
				w.Header().Set("Retry-After", "1")
				Error(w, http.StatusTooManyRequests, "too many requests, retry later")
			}
		})
	}
}
```

`/health` returns the counters:

```go
	r.Get("/health", func(w http.ResponseWriter, req *http.Request) {
		inFlight, refused := api.Load()
		if err := pool.Ping(req.Context()); err != nil {
			api.JSON(w, http.StatusServiceUnavailable, map[string]any{
				"status": "degraded", ..., "database": "unreachable", ...
			})
			return
		}
		api.JSON(w, http.StatusOK, map[string]any{
			"status": "ok", "service": "player-service", "database": "ok",
			"in_flight": inFlight, "max_concurrent": cfg.MaxConcurrentTasks, "refused": refused,
		})
	})
```

The Gateway does the same from its `TaskLimits` middleware (`app/limits.py`, a
module-level `load` dict) in `app/routers/health.py`:

```json
{"status":"ok","service":"gateway","in_flight":0,"max_concurrent":100,"refused":0}
```

`/health` is exempt from the limits, so it still answers when a service is
saturated.

### Discovery checks everyone

Every `HEALTH_INTERVAL` seconds (10), all instances at once (`asyncio.gather`).
Each one gets a state:

```python
async def check(client: httpx.AsyncClient, url: str) -> tuple[str, str]:
    try:
        response = await client.get(url + "/health", timeout=CHECK_TIMEOUT)
        health = response.json()
    except (httpx.HTTPError, ValueError) as exc:
        return "unhealthy", f"no answer from /health ({exc!r})"
    if response.status_code != 200:
        return "unhealthy", f"/health answered {response.status_code}: {health}"

    in_flight = health.get("in_flight", 0)
    limit = health.get("max_concurrent") or 0
    refused = health.get("refused", 0)
    # the counter starts again at 0 when the instance restarts
    newly_refused = max(refused - refused_before.get(url, refused), 0)
    refused_before[url] = refused

    load = in_flight / limit if limit else 0
    detail = (f"{in_flight} of {limit} requests in flight ({load:.0%}), "
              f"{newly_refused} refused since the last check")
    # refusing requests means the instance already hit its limit
    if load >= CRITICAL_LOAD or newly_refused > 0:
        return "critical", detail
    return "ok", detail
```

| State | Meaning |
| --- | --- |
| `ok` | answered `200`, below the critical load |
| `critical` | at least 80% of its limit in use **or** it refused requests since the last check |
| `unhealthy` | no answer within 3 s, or not `200` (for example, its database is down) |

Why "refused since the last check" counts as critical: one check every 10 s
rarely lands on the moment of peak load, but a `429` proves the instance hit its
limit in between. It also makes critical load demonstrable (`Test-HealthCriticalLoad`).

Alerts are raised on a **change** of state, not every round, so a lasting
problem is reported once:

```python
    for (name, url), (status, detail) in zip(instances, results):
        counts[status] += 1
        before = state.get(url, "ok")
        state[url] = status
        if status == before:
            log.debug(...)
        elif status == "ok":
            log.info("%s at %s is back to normal: %s", name, url, detail)
            await notify(client, f"RESOLVED: {name} at {url} is back to normal: {detail}")
        elif status == "critical":
            await alert(client, f"{name} at {url} is under critical load: {detail}")
        else:
            await alert(client, f"{name} at {url} is unhealthy: {detail}")
    ...
    log.info("health check of %d instance(s): %d ok, %d critical, %d unhealthy", ...)
```

`game-public` entries are skipped: they are `localhost` addresses for the
browser, unreachable from inside the discovery container.

Real log lines:

```
health check of 5 instance(s): 5 ok, 0 critical, 0 unhealthy
ALERT: player at http://f5d11a844894:8081 is unhealthy: no answer from /health (ConnectTimeout(''))
health check of 5 instance(s): 4 ok, 0 critical, 1 unhealthy
player at http://f5d11a844894:8081 is back to normal: 0 of 100 requests in flight (0%), 0 refused since the last check
ALERT: player at http://0dc06e9329e8:8081 is under critical load: 0 of 2 requests in flight (0%), 5 refused since the last check
```

---

## 11. Telegram alerts

`alert()` logs and sends; recoveries are sent too:

```python
async def notify(client: httpx.AsyncClient, text: str) -> None:
    """Send a message to the developers' Telegram chat, when one is configured."""
    if not (TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID):
        return
    try:
        response = await client.post(
            f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage",
            json={"chat_id": TELEGRAM_CHAT_ID, "text": text},
            timeout=CHECK_TIMEOUT,
        )
    except httpx.HTTPError as exc:
        # only the kind of error: its text could contain the URL, and with it the token
        log.warning("Telegram message not sent: %s", type(exc).__name__)
        return
    if response.status_code != 200:
        log.warning("Telegram message not sent: %d %s", ...)


async def alert(client: httpx.AsyncClient, message: str) -> None:
    """Tell the developers that an instance needs attention: in the log and on Telegram."""
    log.warning("ALERT: %s", message)
    await notify(client, f"ALERT: {message}")
```

- **No extra infrastructure:** one HTTPS call to the Bot API, no bot server.
- **Failures never stop the checks.** A failed send is logged and the round goes on.
- **The token never reaches the logs.** Only the error *type* is logged, and httpx's request logging is silenced, because the URL contains the token.
- **Configuration:** `TELEGRAM_BOT_TOKEN` (from @BotFather) and `TELEGRAM_CHAT_ID`, both in the git-ignored `.env`. When either is empty, alerts go to the log only. On startup the log says which.

---

## 12. Removal and coming back

### Dropping instances that stopped renewing

Discovery remembers when each instance last registered:

```python
# (service name, URL) -> when that instance last registered, by the monotonic clock
last_seen: dict[tuple[str, str], float] = {}
```

`register` sets it, and `deregister` clears it. Before every health round,
anything silent for longer than `REGISTRATION_TTL` (45 s, three missed renewals)
is dropped:

```python
async def expire(client: httpx.AsyncClient) -> None:
    now = time.monotonic()
    for name, urls in list(registry.items()):
        for url in list(urls):
            silent = now - last_seen.get((name, url), now)
            if silent <= REGISTRATION_TTL:
                continue
            urls.remove(url)
            last_seen.pop((name, url), None)
            log.warning("removed %s at %s: no renewal for %.0fs (%d instance(s) left)", ...)
            await notify(client, f"REMOVED: {name} at {url} stopped renewing ...")
        if not urls:
            del registry[name]
```

This was a real bug, found while testing. A copy killed with `docker kill` never
deregisters. Health checks only alert, and the breaker needs 3 failures within
105 s, which light traffic may never produce. So the dead copy stayed on the list
for good, and the Gateway kept sending it every n-th request. Now it goes within
about a minute even with no traffic:

```
killed player-2 (18fdc4652222), no requests sent
ALERT: player at http://18fdc4652222:8081 is unhealthy: no answer from /health
removed player at http://18fdc4652222:8081: no renewal for 58s (1 instance(s) left)
player instance removed: http://18fdc4652222:8081 (1 left)          <- Gateway
```

Its last renewal was up to 15 s before the kill, and the check runs every 10 s, so
a dead copy leaves between about 30 and 55 s after it dies.

### Every way in and out

| What happens | Who removes it | How it comes back |
| --- | --- | --- |
| `docker stop` / normal shutdown | the instance itself, `POST /deregister` | it registers when started again |
| `docker kill` / crash | Discovery, after 45 s without a renewal; sooner the Gateway breaker, if 3 forwards fail first | it registers when started again |
| Alive but failing briefly (e.g. its database restarting) | the Gateway breaker | its next renewal (≤ 15 s); if it keeps failing, the breaker removes it again |
| Discovery restarts | everyone, since the list was in memory | every renewal (≤ 15 s; the Gateway ≤ 5 s) |
| Discovery down | nobody: the Gateway keeps its last list | renewals resume when it is back |
| Scaled up (`--scale player=3`) | | the new copy registers at startup |

Health checks report and alert; they do not remove on their own. Removal comes
from the breaker (grade 10), which acts on real traffic, and from the missing
renewal, which acts even with no traffic.

---

## 13. Three requests, end to end

### A login

```
browser ──POST /auth/login──► Gateway :8080
  1. TaskLimits: in_flight +1 (429 if already at MAX_CONCURRENT_TASKS)
  2. route: "auth" -> player
  3. pick("player") -> http://41f0f430470b:8081   (next time: the other copy)
  4. forward_http, credentials stripped, X-Forwarded-* added
  5. player-1 checks the password, signs the JWT, answers 200
  6. 5xx or timeout? breaker.failure(...)       200? nothing to count
  7. log "forwarded to player at http://41f0f430470b:8081: 200 in 95 ms"
browser ◄── 200 {"access_token": ...}
```

### Watching a game

```
browser ──GET /ws/game (Bearer token)──► Gateway
          pick("game-public") -> ws://localhost:8083/game
browser ──ws://localhost:8083/game?session_id=S──► game-2 (holds the socket)

meanwhile game-1 holds the clock lock:
  game-1 engine: session S -> night   ──► pg_notify('game_events', {phase_changed, S})
  Postgres ──► game-1 LISTEN (no watcher of S there)
           ──► game-2 LISTEN ──► deliver to the browser's socket
browser ◄── {"type":"phase_changed","session_id":"S",...}
```

### A Player copy crashes

```
docker kill player-2
  t+0     Gateway still has it in the list, every other login -> 503
  t+~10 s Discovery: ALERT unhealthy   ──► Telegram "ALERT: player at ... is unhealthy"
  then whichever comes first:
    busy:  3rd 503 within 105 s -> Gateway breaker TRIPPED -> removed + POST /deregister
    quiet: no renewal for 45 s  -> Discovery drops it      ──► Telegram "REMOVED: ..."
  every request now reaches player-1; nothing renews player-2, so it stays out

docker start player-2
  registers at startup -> Gateway "player instance added (2 now)" within 5 s
  Discovery: "back to normal"          ──► Telegram "RESOLVED: ..."
```

---

## 14. Configuration

| Variable | Where | Default | Meaning |
| --- | --- | --- | --- |
| `INTERNAL_KEY` | all | `changeme` | `X-Internal-Key`, also required by Discovery |
| `DISCOVERY_URL` | Player, Game, Gateway | empty | Discovery to register with / read from; empty = run standalone, fixed URLs |
| `SERVICE_URL` | Player, Game | `http://<hostname>:<PORT>` | the address registered |
| `PUBLIC_URL` | Game | empty | browser address, registered as `game-public` |
| `DISCOVERY_REFRESH` | Gateway | `5` | seconds between two reads of the list (and self-registrations) |
| `PLAYER_REPLICAS` | compose | `2` | Player copies |
| `GAME_2_PORT` | compose | `8083` | host port of `game-2` |
| `HEALTH_INTERVAL` | Discovery | `10` | seconds between health rounds |
| `CRITICAL_LOAD` | Discovery | `0.8` | share of `max_concurrent` that is critical |
| `REGISTRATION_TTL` | Discovery | `45` | seconds without a renewal before an instance is dropped |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | Discovery | empty | Telegram alerts; empty = log only |
| `TASK_TIMEOUT` | all | `30` | request time limit; the breaker window is 3.5 × this |
| `MAX_CONCURRENT_TASKS` | all | `100` | requests at once before `429`; the `max_concurrent` on `/health` |

Fixed in code: 3 failures to trip; retry registration every 5 s and renew every
15 s; 3 s timeout for a health check; advisory locks `7000` (schema) and `7001`
(clock); NOTIFY channel `game_events`.

Run the current code (the Docker Hub images predate this lab):

```powershell
docker compose -f compose.yml -f compose.local.yml up -d --build
```

---

## 15. Known limits

- **`game-public` stays when a Game copy is removed.** The Gateway does not know which public address belongs to which copy, and Discovery cannot check those addresses.
- **Game's breaker window is fixed.** Once Game's breaker trips, calls to that target stay off for the full 105 s, even if it recovers sooner.
- **Discovery is a single process with an in-memory list.** Renewal rebuilds the list after a restart, but while Discovery is down the Gateway routes on its last known list, and nothing new can join.
- **Round robin ignores load.** Requests are spread evenly, whatever each copy is doing. Health checks report load; they do not steer traffic.
- **Teammates' services do not register.** They are reached at fixed URLs, are not health-checked, and are not balanced.
