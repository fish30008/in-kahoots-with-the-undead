# How the system works

A walk through one request, from the client to the database and back, for the
three pieces that are ours: the **Gateway**, the **Player Service** and the
**Game Service**. Each service has its own `flow.md` describing its code; this
file describes how they talk to each other.

---

## 0. The map in one picture

```
                      client (Postman, browser)
                         |                 :
              REST, all of it              :  WebSocket, after asking
                         |                 :  the Gateway for the URL
                         v                 :
                +------------------+       :
                |     Gateway      |       :
                |  Python :8080    |       :
                +------------------+       :
                  |       ^      |         :
     /auth        |       |      |  /game  :
     /players     |       |      |         :
     /trades      |       |      v         v
                  v       |    +------------------+
        +----------------+|    |   Game Service   |
        | Player Service |+----|   Go :8082       |
        | Go :8081       | REST +------------------+
        +----------------+ via            |
                |          Gateway        |
                v                         v
           player-db                   game-db
           (Postgres)                  (Postgres)
```

Three rules hold the design together:

1. **One door.** Every REST request goes to the Gateway on port 8080, whether it
   comes from a client or from another service. Nobody calls a service directly.
2. **Credentials stop at the door.** The Gateway checks the token. The services
   behind it never see it.
3. **One database per service.** Game never reads Player's tables. When it needs
   a player, it asks over REST.

Besides REST there are **events**: when something happens that another service
reacts to, the service that owns it publishes an event on its own WebSocket and
the others read it. Section 6 covers that.

---

## 1. What each piece does

| Piece | Language | Port | Job |
| --- | --- | --- | --- |
| Gateway | Python, FastAPI | 8080 | Checks who is calling, picks the service, forwards the request, enforces limits. No database. |
| Player Service | Go, chi | 8081 | Accounts, login, XP and level, inventory, item catalog, trades. Issues the access token. Publishes `player.registered` and `player.leveled_up`. |
| Game Service | Go, chi | 8082 | Sessions, actions, zombies, the day/night tick loop, the live WebSocket. Publishes `game.action_completed`. |

The Gateway picks the service from the **first part of the path**:

| Path starts with | Goes to |
| --- | --- |
| `/auth`, `/players`, `/trades` | Player Service |
| `/game` | Game Service |
| `/exams`, `/world`, `/zombies`, `/resources`, `/base`, `/crafting` | the teammates' services |
| anything else | `404` from the Gateway |

The path is forwarded unchanged: `GET /game/sessions` on the Gateway becomes
`GET /game/sessions` on the Game Service.

---

## 2. Logging in

```
client                    Gateway                   Player Service
  |  POST /auth/register     |                            |
  |------------------------->|  public route, no token    |
  |                          |--------------------------->|  bcrypt the password,
  |                          |                            |  insert the player
  |<-------------------------|<---------------------------|  201 + player
  |                          |                            |
  |  POST /auth/login        |                            |
  |------------------------->|  public route, no token    |
  |                          |--------------------------->|  compare the hash,
  |                          |                            |  sign a token
  |<-------------------------|<---------------------------|  200 + access_token
```

`POST /auth/register` and `POST /auth/login` are the only routes that pass
without a token.

A player id is an integer, handed out in order starting at 1. Every service uses
that same number for the player.

The token is a JWT signed with HS256 and the value of `JWT_SECRET`. It carries
the player id in `sub`, the username, and an expiry 24 hours ahead. The answer
holds it twice: in the JSON body as `access_token`, and as an `access_token`
cookie.

The Gateway has the same `JWT_SECRET`, which is how it can verify a token it did
not issue. If the two values differ, every request after login is `401`.

---

## 3. A normal request

`GET /game/sessions` with `Authorization: Bearer <token>`:

1. **Limits.** If the Gateway is already handling `MAX_CONCURRENT_TASKS`
   requests, it answers `429` with `Retry-After` and stops.
2. **Who is calling.** The Gateway reads the token from the `Authorization`
   header, or from the `access_token` cookie. Missing or invalid means `401`,
   and the request never reaches a service.
3. **Where to.** The first path segment is `game`, so the target is the Game
   Service.
4. **Forward.** The `Authorization` header and the `access_token` cookie are
   removed. An `X-Player-Id` header with the id from the token is added.
5. **Answer.** Whatever the Game Service returns, status and body, goes back to
   the client unchanged.

What can go wrong on the way, and who answers:

| Status | Who | Why |
| --- | --- | --- |
| `401` | Gateway | No token, expired token, wrong signature |
| `404` | Gateway | No service owns the path, or the path is `/<prefix>/internal/...` |
| `429` | Gateway or service | Too many requests at once |
| `503` | Gateway | The service is down or unreachable |
| `504` | Gateway | The service took longer than `TASK_TIMEOUT` |
| `408` | service | The service's own work took longer than `TASK_TIMEOUT` |

Errors made by the Gateway look like `{"error": {"code": "...", "message": "..."}}`.
Errors made by our Go services look like `{"error": "..."}`.

---

## 4. Game calling Player and World

The Game Service owns no player data and no map, so it asks for them:

| When | Call |
| --- | --- |
| A player joins a session | `GET /players/{id}` to check the player exists |
| A player joins or leaves | `PUT /players/{id}/presence` to flip `online` |
| An action starts | `GET /world/rooms/{id}`: the room must exist and be unlocked, and `scavenge` needs a room with a resource node |
| An action finishes | `POST /players/{id}/xp` |
| A tourist zombie steals | `GET /players/{id}/inventory`, `POST /players/{id}/inventory/consume` |

These calls also go **through the Gateway**: in `compose.yml` the Game Service's
`PLAYER_SERVICE_URL` and `WORLD_SERVICE_URL` are both `http://gateway:8080`.

```
Game Service                 Gateway                  Player Service
  |  POST /players/{id}/xp     |                            |
  |  X-Internal-Key: <key>     |                            |
  |--------------------------->|  key matches, no token     |
  |                            |  needed                    |
  |                            |--------------------------->|
  |<---------------------------|<---------------------------|
```

A service has no player token, so it sends `X-Internal-Key` instead. The Gateway
compares it with its own `INTERNAL_KEY`; when they match the caller counts as a
service. Both sides must have the same value.

This is why `online` stays `false` right after login: logging in does not change
it. It turns `true` when the player joins a session, because that is when Game
calls the presence route.

---

## 5. The live WebSocket

The Gateway does not carry WebSocket traffic. It only tells the client where the
socket is, and the client connects there itself.

```
client                     Gateway                    Game Service
  |  GET /ws/game             |                             |
  |  Bearer <token>           |                             |
  |-------------------------->|  checks the token           |
  |<--------------------------|  {"url":"ws://localhost:8082/game", ...}
  |                                                         |
  |  ws://localhost:8082/game?session_id=<id>               |
  |-------------------------------------------------------->|
  |<============ game state, every tick ====================|
```

The client adds `?session_id=<id>` to the URL it was given. This is the one case
where the client talks to a service directly, which is why port 8082 is
published in `compose.yml`.

The socket is a plain WebSocket, and it does not check a token itself. Only the
`GET /ws/game` call does.

---

## 6. Events between services

REST is for when the caller needs the answer to continue. An event is for
"this happened, whoever cares can react", and the publisher does not wait.

```
Player Service                                  Base, Crafting, Resource
  | register / level up                                   |
  | write the row AND the event, one transaction          |
  |   (table outbox_events)                               |
  |                                                       |
  |        GET /ws/player  (asked of the Gateway, with X-Internal-Key)
  |        -> {"url": "ws://player:8081/events"}          |
  |<======== WebSocket ws://player:8081/events ===========|
  |  <- {"op":"subscribe","types":[...],"since":0}        |
  |  -> {"op":"event","seq":1,"event":{...}}              |
  |  <- {"op":"ack","seq":1}                              |
```

| Event | Published by | When | Read by |
| --- | --- | --- | --- |
| `player.registered` | Player | `POST /auth/register` | Base (creates the starting base), Resource (creates the balances) |
| `player.leveled_up` | Player | `POST /players/{id}/xp` raised the level | Crafting |
| `game.action_completed` | Game | a timed action reached its deadline | Resource (credits wood, or what the room's node holds) |

How it works, the same in both services:

1. **The outbox.** The event is inserted into `outbox_events` in the same database
   transaction as the change that caused it. Either both are saved or neither.
2. **The stream.** `GET /events` is a WebSocket for other services. The consumer
   says which event types it wants and the last `seq` it has seen; the service
   sends everything after that and then keeps sending new rows, checking the
   table once a second.
3. **The Gateway only negotiates**, exactly like the game socket: the consumer
   asks `GET /ws/player` or `GET /ws/game` and then connects directly.
4. **Old events go.** Rows older than 7 days are deleted once an hour.

So finishing `chop_benches` takes two paths at once: Game pays the XP to Player
over REST, and Resource hears about it from the event and adds the wood.

---

## 7. Limits

Both limits exist in the Gateway and in each of our services, set by the same
two variables.

| Variable | Default | Meaning |
| --- | --- | --- |
| `MAX_CONCURRENT_TASKS` | `100` | Requests handled at the same time. One more is refused with `429`. |
| `TASK_TIMEOUT` | `30` | Seconds one request may take. |

`/health` is outside both limits, so a health check answers even when the
service is full. The WebSocket routes are outside them too, because a socket is
meant to stay open.

---

## 8. Configuration that must match

| Variable | Set on | Must equal |
| --- | --- | --- |
| `JWT_SECRET` | Player, Gateway | each other, or every token is rejected |
| `INTERNAL_KEY` | Player, Game, Gateway and the teammates' services | each other, or service-to-service calls and `/events` connections get `401` |
| `PLAYER_SERVICE_URL`, `WORLD_SERVICE_URL` | Game | the Gateway, `http://gateway:8080` |
| `GAME_PUBLIC_WS_URL` | Gateway | the Game Service address as seen from the host, `ws://localhost:8082` |

---

## 9. Running it

```bash
docker compose up -d
```

| Address | What |
| --- | --- |
| `http://localhost:8080` | Gateway, the address every client uses |
| `http://localhost:8081/health` | Player Service health check |
| `http://localhost:8082/health` | Game Service health check |
| `ws://localhost:8082/game?session_id=<id>` | live socket |

Then run the collections in `postman/`: they register a player, log in, and send
every other request through the Gateway with the token. The game collection needs
`DEMO_SPEEDUP=60` in `.env`, so that a five minute action takes five seconds.
