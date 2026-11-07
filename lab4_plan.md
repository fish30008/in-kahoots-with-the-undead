# Lab 4 plan: Breaking and Brokering

Source: `wrapper/broker_service/reuirements/PAD_LAB_4_V1.pdf`. Ten grades, built in
five milestones of two grades each.

## Decisions already made

| Topic | Decision |
|---|---|
| Broker language | Python, the team's banned language (stdlib `ThreadingHTTPServer` + `grpcio`, no FastAPI) |
| Broker product | None: the broker is written by us. Kafka/RabbitMQ would make grades 5-10 configuration instead of implementation |
| Broker repo | `fish30008/broker_service`, added as the submodule `services/broker_service` |
| Scope | Our services move to the broker and gRPC: Gateway, Player, Game, Discovery, Broker. Teammates' images are not changed; they only get new URLs in `compose.yml` |
| Monitoring | Prometheus + Grafana + Loki |
| Commits | On `main`, subject of at most 10 words, no body, no co-author trailer, `CLAUDE.md` never committed |

## What "one commit" means here

A milestone touches several git repos (the broker, some submodules and this
integration repo), and each repo needs its own commit. So "5 commits" means
**at most one commit per repo per milestone**, plus the commit here that moves the
submodule pointers. All subjects follow the rules above, e.g. `broker skeleton with
health check and publish workflow`.

Images: during a milestone the images are built locally with the tag compose
expects (`docker build -t fish3008/<repo>:4 .`), so `docker compose up` uses them
without publishing. Each repo is tagged `4` and published once, at the end of
milestone 5. A milestone that has to be presented earlier can be published early;
the publish workflow only builds from tags, so re-tagging means deleting the old tag
first.

## The target picture

```
browser ──REST──> Gateway ──REST──> Broker ──REST/gRPC──> Player / Game instances
                  (auth, JWT)        │  queue per service (gateway → service)
                                     │  topics (service → whoever subscribed)
                                     │  load balancing, circuit breakers, retries
                                     │  durable store (SQLite) + dead letters
Game ──gRPC──> Broker ──gRPC──> Player        (service-to-service, no gateway)
Player/Game ──gRPC Publish──> Broker ──gRPC Deliver──> subscribers of the topic
Discovery <── every instance registers name, url, grpc url and topics
Prometheus <── /metrics of every service      Loki <── every container's logs
Grafana shows both
```

The Gateway stays the only door for users. The Broker is the door for everything
that happens between services.

---

## Milestone 1: grades 1 and 2 (broker skeleton)

**Grade 1 (Breathe)** is free.

**Grade 2: create the broker and set up its repo the same way as Gateway and Discovery.**

Work in `services/broker_service`:

- `git submodule add https://github.com/fish30008/broker_service services/broker_service`
- Layout copied from `service_discovery`, kept flat:
  `app/main.py` (server and routes), `app/config.py` (env), `requirements.txt`,
  `Dockerfile`, `.env.example`, `.dockerignore`, `.gitignore`, `README.md`.
- HTTP server: `http.server.ThreadingHTTPServer`, not FastAPI. It starts **one thread
  per request**, so grade 7 is designed in from day one rather than rewritten
  later. Port `8070`.
- `GET /health` returns `{"status":"ok","service":"broker","in_flight":0,"max_concurrent":N,"threads":K}`,
  the same fields Discovery already reads from the other services.
- The broker registers itself with Discovery like the others (every 15s, deregisters
  on shutdown).
- `.github/workflows/docker-publish.yml` copied from `service_discovery`: a push to
  `main` builds the image; a bare lab-number tag (`4`) publishes
  `fish3008/broker_service:4` and `:latest`, and fails if the tagged commit is not on `main`.
- Logs start in the new format (see "Log format" below): `[broker-http]`, `[broker-discovery]`.

Here: add a `broker` service to `compose.yml` (no route through it yet) and commit the
submodule.

**Done when:** `curl localhost:8070/health` answers, the broker shows up in Discovery's
`/services`, and the CI build passes on `main`.

---

## Milestone 2: grades 3 and 4 (docs, log download, clean logs)

**Grade 3: README, architecture diagram, Postman.**

- `README.md` here is stale (Lab 1). Rewrite it for the real system: services, ports,
  how to run, the broker's place. It links to `flow.md` instead of repeating it.
- `architecture.mmd`: add the Broker between Gateway and services, the topic arrows,
  and Prometheus/Grafana/Loki drawn as planned. Re-render `architecture.png` with
  the command in `CLAUDE.md`.
- Postman: add a `broker` folder (`/health` for now) and a `logs` request (below).
  Check that every existing request still passes.
- The diagram and README are touched again in milestone 5 so they match the end
  state; grade 3 asks only that they show the new component.

**Grade 4: an endpoint to download logs from the system.**

Design:

1. Every one of our services (gateway, discovery, player, game, broker) writes each
   log line to stdout **and** to `/logs/<service>-<hostname>.log`, a file on a
   shared Docker volume `logs`. The hostname keeps the two Player replicas apart.
   Files rotate at 5 MB, 3 kept, so the volume cannot fill the disk.
2. The Gateway mounts the volume read-only and serves
   `GET /logs?service=game&level=WARN&lines=500`:
   - no `service`: all files, merged and sorted by time;
   - the response is `text/plain` with `Content-Disposition: attachment;
     filename=logs-<time>.log`, so Postman and the browser download it;
   - it is protected by the `X-Internal-Key` header, because logs are for
     developers, not players.
3. Teammates' containers are not in the files. Their logs reach Loki in
   milestone 5 instead. If the defence needs them earlier, the alternative is to mount
   `/var/run/docker.sock` read-only into the Gateway and read container logs through
   the Docker API.

**The log cleanup we agreed on happens here**, because this is the first milestone
that changes the existing services. See "Log format" below. Summary:

- every line carries a `[service-component]` tag and a level;
- uvicorn access logs are off (gateway, discovery, broker);
- chi `middleware.Logger` is replaced by a short logger that skips `/health`;
- the gateway's two lines per request become one;
- Discovery's health summary is logged only when the counts change;
- the gateway sends `X-Request-Id`, and the services log it as `req=…`.

Commits: one each in gateway, discovery, player, game and broker; one here (README,
diagram, Postman, `logs` volume in compose, pointers).

**Done when:** an idle stack is quiet; one request shows the same `req=` in gateway
and service; `GET /logs` downloads a file containing all five services.

---

## Milestone 3: grades 5 and 6 (the broker carries the traffic)

**Grade 5: the broker in the middle, with Load Balancing and Circuit Breakers moved
into it.**

- **Routing by path, the same as the gateway.** The broker reads the first path
  segment (`/players` → player, `/game` → game, `/exams` → exam, …) and forwards to
  one instance of that service. That makes it a drop-in replacement for the gateway's
  role between services:
  - Game's `PLAYER_SERVICE_URL`, `WORLD_SERVICE_URL` and `EXAM_SERVICE_URL` change from
    `http://gateway:8080` to `http://broker:8070`;
  - teammates' `*_URL` variables in `compose.yml` that point at the gateway point at
    the broker instead. Their images do not change.
- **Load balancing moves.** `pick()` (round robin over Discovery's list) and the list
  refresh move from `gateway_service/app/discovery.py` to the broker.
- **Circuit breaker moves.** `gateway_service/app/breaker.py` (3 failures within
  3.5 × timeout trips the instance and deregisters it) moves to the broker. Game's own
  Go breaker stays, because it protects Game's calls into the broker.
- **The gateway becomes simpler.** It authenticates, then sends every request to
  `http://broker:8070`. It no longer knows about instances, and Discovery no longer
  needs to be read from the gateway.
- **Dockerize and publish:** the image builds in CI (published with tag `4` at the
  end, or earlier if this milestone is presented).

**Grade 6: two kinds of queue.**

*Subscriber-based queues (Gateway → service).* There is one queue per service. The
gateway knows the destination and puts the request on that service's queue:

```
Gateway: POST /queues/player  {id, method, path, headers, body}   (waits for the reply)
Broker:  queue "player" ─> worker thread ─> one player instance ─> reply ─> gateway
```

- Point-to-point: each message goes to exactly one instance (competing consumers),
  chosen by the load balancer.
- Request/reply: the broker thread handling the gateway's request waits on the
  reply (correlation id = message id), with the task timeout.
- The queue is bounded. When it is full the broker answers `429`, the same rule the
  services already follow.

*Topic-based queues (service → service).* The producer does not know who listens:

```
Player: POST /topics/player.leveled_up  {event}
Broker: subscribers of player.leveled_up = [game]  ─> one game instance
```

- **Subscribing is part of registration:** every instance sends Discovery
  `{"name","url","topics":["player.leveled_up"]}`. Discovery stores the topics and
  returns them from `/services`; the broker builds its topic → services table from that.
- **Fan-out across services, competition within one:** each subscribing *service*
  gets the event once, delivered to one of its instances.
- **Producers publish from the outbox.** The outbox stays: a relay goroutine in
  Player and Game reads unpublished rows, publishes them to the broker, and marks
  them published only after the broker acks. A broker restart therefore never loses
  an event. `GET /events` stays for teammates' consumers (scope decision).
- **A real consumer, for the demo:** Game subscribes to `player.leveled_up` and
  sends a `player_leveled_up` frame to the sessions that player is in. Player
  subscribes to `game.action_completed` for nothing more than a log line; it shows
  one event reaching two kinds of consumer (Player and teammates' Resource).

Commits: broker; gateway (LB/CB removed, sends to the queue); discovery (topics in
registration); player and game (topics, outbox relay, consumer endpoint); here
(compose URLs, flow.md section on the broker, Postman).

**Done when:** killing one player replica during a Postman run only produces
breaker logs in the broker; a level-up shows up live in the game WebSocket.

---

## Milestone 4: grades 7 and 8 (threads, topics list, gRPC, closing the door)

**Grade 7: thread-per-request, and a topics endpoint.**

- `ThreadingHTTPServer` already gives each request its own thread. Grade 7 makes this
  visible and correct:
  - each request thread is named `req-<id>` and the name appears in the broker's logs;
  - `/health` and `/metrics` report how many threads are alive;
  - shared state (queues, breaker counts, round-robin index, topic table) is guarded
    by `threading.Lock`, because these threads really do run concurrently;
  - a semaphore caps concurrent requests at `MAX_CONCURRENT_TASKS` (answers `429`).
- Why threads are fine in Python here: the broker only waits on the network, and the
  GIL is released while a thread waits for I/O.
- `GET /topics` returns every known topic with its subscribers, the number of
  messages published, and the number waiting.

**Grade 8: gRPC for service-to-service, and remove internal routes from the gateway.**

- One `proto/` folder in the broker repo, copied into each Go service:
  - `player.proto`: `Player` service with `Get`, `AddXP`, `SetPresence`,
    `ConsumeItem`, `Inventory`, the calls Game makes today over REST;
  - `events.proto`: `Broker.Publish(Event)` and `Consumer.Deliver(Event)`.
- **The broker does not need to know the protos for calls.** It registers a generic
  gRPC handler: a call to `/player.Player/AddXP` is forwarded as raw bytes to a player
  instance chosen by the same load balancer and breaker. Adding an RPC to Player
  needs no change in the broker.
- Player starts a gRPC server on `:9081`; Game uses a gRPC client (to `broker:50051`)
  instead of `playerclient`'s REST calls. Game starts a gRPC server on `:9082` only for
  `Consumer.Deliver`.
- Instances register their `grpc_url` with Discovery next to `url`.
- Calls to teammates' services (World, Exam) stay REST through the broker, which is
  allowed by the scope decision.
- **The gateway closes:** it drops every route a user must never call: the
  `X-Internal-Key` caller type, `/<prefix>/internal/...`, and `/ws/<producer>`
  negotiation for event streams (moved to the broker as `GET /ws/<service>` for
  teammates). The REST `/internal` endpoints of Player and Game that gRPC replaced
  are deleted.

Commits: broker, player, game, gateway, discovery (`grpc_url` stored), here
(compose ports, flow.md, Postman: the internal requests move to a "via broker" folder).

**Done when:** `go build ./... && go vet ./...` pass; a tourist zombie still steals
through gRPC; `GET localhost:8080/players/internal/...` is `404`.

---

## Milestone 5: grades 9 and 10 (reliability and monitoring)

**Grade 9: durable queues and a dead letter channel.**

- **Durable:** every topic message is written to SQLite (`/data/broker.db` on a volume)
  *before* the broker acks the publisher. A delivery is deleted only after the
  subscriber acks. After a restart, the broker resends everything not acked.
  Table: `messages(id, topic, subscriber, payload, attempts, next_attempt_at, last_error)`.
- **Retries:** backoff of 1s, 2s, 4s, 8s, 16s.
- **Dead letters:** a message goes to `dead_letters` when it
  - failed 5 deliveries,
  - is older than its TTL (default 1 hour), or
  - cannot be decoded / names no known topic.
  The row keeps the payload, the reason and the last error.
- `GET /dead-letters` lists them (newest first, `?topic=` filter). There is also
  `POST /dead-letters/{id}/retry` to put one back in the queue, which is useful for the
  demo.
- Request/reply queues (gateway → service) are not made durable: the gateway is
  waiting synchronously, and replaying a stale request later would be wrong. This is
  explained at the defence rather than built.

**Grade 10: high availability, load-based routing, monitoring.**

- **Rerouting:** when a call fails in a way that trips the instance's breaker or
  never reached it (connection refused, breaker open), the broker retries **once on
  the next healthy instance** before answering. Only a call that timed out *after*
  being sent is not retried for POST/PATCH/DELETE, because it might already have
  happened.
- **Load-based balancing:** choose the instance with the lowest
  `in_flight / max_concurrent`. Two inputs:
  - the broker's own count of calls in flight to each instance (exact and instant);
  - the load Discovery reads from each `/health` every 10s (covers traffic the broker
    did not send).
  Ties fall back to round robin. Logs show the choice: `[broker-lb] player: picked
  player-2 (1/50) over player-1 (7/50)`.
- **Prometheus + Grafana + Loki** in `monitoring/` here, started by compose:
  - every one of our services serves `GET /metrics` (`prometheus_client` in Python,
    `client_golang` in Go): requests by route/status, duration histograms, in-flight;
    for the broker also queue depth, topic publish/deliver counts, DLQ size, breaker
    trips, reroutes; for Game also active sessions, zombies spawned, actions
    completed;
  - Prometheus scrapes them (instances found through Discovery or static names);
  - Promtail reads **every** container's stdout (teammates' too) and sends it to
    Loki; the `[service-component]` tag is parsed into labels;
  - Grafana is provisioned from files: Prometheus and Loki data sources plus one
    dashboard ("Requests and errors per service", "Broker queues and DLQ", "Breaker
    trips and reroutes", "Game activity", and a logs panel filtered by tag).

**Release:** tag `4` and push in broker, gateway, discovery, player, game; wait for
each image to publish; set tags to `4` in `compose.yml`/`.env`; final README and
diagram; commit the pointers here.

**Done when:** stopping a Game replica mid-run causes no client errors; the DLQ list
fills when a subscriber is stopped longer than its retries; Grafana shows live
traffic and logs from every container.

---

## Log format (applied from milestone 2)

```
2026-11-04T12:00:01Z INFO  [gateway-proxy]  GET /players/me player=7 -> player 200 12ms req=a1b2c3
2026-11-04T12:00:01Z INFO  [player-http]    GET /players/me 200 3ms req=a1b2c3
2026-11-04T12:00:05Z INFO  [game-engine]    session 4f2e day -> night, cycle 3
2026-11-04T12:00:09Z WARN  [broker-breaker] player-1 failed (503): 2 of 3 within 35s
2026-11-04T12:00:10Z ERROR [broker-dlq]     game.action_completed to resource dead after 5 attempts
```

- Time in UTC, a level (`INFO`, `WARN`, `ERROR`), then `[service-component]`, then
  the message, ending with `key=value` pairs where they help (`req=`, `player=`, `session=`).
- Tags: `gateway-{proxy,auth,limits,logs}`, `broker-{http,queue,topic,lb,breaker,dlq,grpc,discovery}`,
  `player-{http,auth,events,grpc,discovery,db}`,
  `game-{http,engine,zombie,action,hub,events,grpc,breaker,discovery,db}`,
  `discovery-{registry,health,alert}`.
- Go: plain `log.Printf("INFO [game-engine] …")` with UTC flags, no logging library.
  Python: logger named after the tag, format `%(asctime)s %(levelname)-5s [%(name)s] %(message)s`.
- Only changes and real work are logged: no `/health`, no routine re-registrations,
  no repeated "still fine" lines.
