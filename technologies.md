# Technologies & Stack Choices

## 1. Stack

One language, one database, no extra infrastructure.

| Layer | Choice |
|---|---|
| Language | Go |
| HTTP framework | Gin (`gin-gonic/gin`) |
| Database | PostgreSQL (one database per service) |
| Transport | HTTP with JSON bodies, used both synchronously and asynchronously |
| Concurrency | Goroutines (standard library) |
| Packaging | Docker, orchestrated with Docker Compose |

There is no message broker, no cache and no authentication layer. Asynchronous
delivery is done with goroutines over the same HTTP endpoints, so the only
runtime dependencies are the service binaries and PostgreSQL.

## 2. Services

| Service | Port | Owns |
|---|---|---|
| **Player** | 8081 | Players and their inventory |
| **Game** | 8082 | Game sessions and the players joined to them |

Each service is a separate Go module with its own PostgreSQL database. A service
never reads another service's database; it asks over HTTP instead.

## 3. Communication model

Service-to-service calls come in two shapes, chosen by one question: **does the
caller need the answer before it can continue?**

### Synchronous — the caller needs the answer

A blocking HTTP request with a timeout. The caller cannot proceed without the
response, so it waits for it and propagates the failure if the call fails.

```go
// Game must know the player exists before joining them to a session.
ctx, cancel := context.WithTimeout(c.Request.Context(), 2*time.Second)
defer cancel()

p, err := playerClient.GetPlayer(ctx, playerID)
if err != nil {
    c.JSON(http.StatusBadGateway, gin.H{"error": "player service unavailable"})
    return
}
```

### Asynchronous — nobody is waiting

The handler responds immediately and a goroutine performs the call in the
background. The goroutine gets its own `context.Background()` timeout, because
the request context is cancelled the moment the handler returns.

```go
// A player came online; Player is told, but Game does not wait for it.
go func() {
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()

    if err := playerClient.SetPresence(ctx, playerID, true, eventID); err != nil {
        log.Error("presence notify failed", "player", playerID, "err", err)
    }
}()

c.JSON(http.StatusCreated, session)
```

### Which calls are which

| Interaction | Shape | Why |
|---|---|---|
| Game → Player: fetch a player before joining a session | Synchronous | The join is rejected if the player does not exist |
| Game → Player: apply damage or grant XP | Synchronous | Game needs the resulting HP, and a lost reward corrupts player state |
| Game → Player: player went online / offline | Asynchronous | An `online` flag; a stale one is harmless and the next call corrects it |
| Game → Player: a session was created or ended | Asynchronous | Informational; the session is already valid without it |

Receivers must tolerate a notification arriving twice or not at all: an
asynchronous endpoint is idempotent on the event id it is given.

## 4. Why this stack

- **Go** — one language across the system keeps builds, Dockerfiles and HTTP
  client code identical in every service. Goroutines make asynchronous delivery
  a language feature rather than an added component.
- **Gin** — request binding and struct-tag validation are most of what a CRUD
  handler does, and Gin provides both (`ShouldBindJSON`, `binding:"required"`)
  with almost no boilerplate.
- **PostgreSQL** — relational data (a player owns items, a session has members)
  with real foreign keys and transactions. One database per service keeps the
  services independently deployable.
- **HTTP for both shapes** — the asynchronous path posts to an ordinary REST
  endpoint, so one contract and one client serve both. Adding a broker later
  means changing the transport, not the contract.

## 5. Trade-offs

| Decision | Gain | Cost |
|---|---|---|
| Single language | One toolchain, shared client patterns | No language-per-workload tuning |
| One DB per service | Independent schemas and deploys | Cross-service data needs an HTTP call, not a join |
| Goroutine async instead of a broker | Zero extra infrastructure; async without operating a queue | **No durability** — an in-flight notification is lost if the process stops, and there is no retry or replay |
| Synchronous only where the answer is needed | Game stays available when Player is down for everything except joins | Joins fail while Player is down |
| No authentication | Nothing to configure to run or test the system | Every endpoint is open; auth is a later addition |

The durability cost is the one that matters: notifications are best-effort.
Anything that must not be lost belongs in a synchronous call, or in the
receiver's own database via a request the caller retries.

## 6. Out of scope (for now)

Authentication and sessions, real-time push to clients, a message broker with
durable queues, caching, and service discovery. These are deliberate omissions,
not oversights — each would be added on top of the HTTP contract without
changing it.

## 7. Implementation status

| Service | State |
|---|---|
| Player | `services/player_service/` — submodule, no Go source yet |
| Game | `services/game_service/` — submodule, implementation in progress |

A service counts as implemented once it has Go source, a Dockerfile, and a
documented way to run it.
