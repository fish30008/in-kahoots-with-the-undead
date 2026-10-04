# Communication Contract

## Conventions

**Type notation:** `string`, `int`, `float`, `bool`, `uuid`, `datetime` (ISO 8601, UTC), `enum(a|b)`,
`[T]` list, `map<K,V>`, `T?` nullable/optional.

| Service | Port | Path prefix |
|---|---|---|
| Player | 8081 | `/auth`, `/players`, `/trades` |
| Game | 8082 | `/game` |
| Exam | 8083 | `/exams` |
| World | 8084 | `/world` |
| Zombie | 8085 | `/zombies` |
| Resource | 8086 | `/resources` |
| Base | 8087 | `/base` |
| Crafting | 8088 | `/crafting` |

**Caller:** `client` = the game client acting as a logged-in player; `internal` = another service.

**Errors** — every non-2xx response has the same body:

```json
{ "error": { "code": "INSUFFICIENT_RESOURCES", "message": "Need 10 wood, have 4" } }
```

`401 UNAUTHENTICATED`, `403 FORBIDDEN` and `400 VALIDATION_ERROR` apply everywhere and are not
repeated per endpoint.

**Idempotency** — endpoints marked **Idempotent: yes** require an `Idempotency-Key: <uuid>` header.
A repeated key returns the original response and performs no second write. Keys are kept for 24h.

---

## Authentication

### Player session

`POST /auth/login` sets a cookie. The client never handles the token directly.

```
Set-Cookie: access_token=<jwt>; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=86400
```

The cookie is a JWT signed by Player Service with RS256:

```json
{ "sub": 42, "username": "razvan", "iat": 1757440000, "exp": 1757526400 }
```

Every service verifies the signature locally with Player Service's public key from `GET /auth/jwks`
(cached, refreshed hourly, `kid` selects the key). No service calls Player Service to validate a
request. `sub` is the authenticated player id; endpoints taking a `{id}` for a player return
`403 FORBIDDEN` if it differs from `sub`, unless the caller is internal. The WebSocket handshake
sends the same cookie.

### Service-to-service

Internal endpoints require `X-Internal-Key: <shared secret>` (from environment, never committed).
A service acting for a player also sends `X-Player-Id: <int>` so the callee can attribute the write.
The same `X-Internal-Key` header authenticates the handshake of a service event connection (see
[Service events](#service-events)).

---

## Data ownership

Each service owns its own database instance. No shared tables, no cross-service joins, no reading
another service's DB. Data owned elsewhere is fetched over REST or received via [service
events](#service-events).

| Service | Store |
|---|---|
| Player, Exam, World, Zombie, Base, Crafting, Resource | PostgreSQL, one database per service |
| Game | Redis (live session and timer state), PostgreSQL (session history) |

---

## Service events

Sync REST when the caller needs the answer to continue. WebSocket events when something happened
that other services react to. There is no message broker: every producing service serves its own
events over a WebSocket and consumers connect to it.

### Connection

A producer exposes `GET /events`, upgraded to a WebSocket, on its normal port (e.g.
`ws://exam:8083/events`). The consumer is the client: it opens the connection, authenticates the
handshake with `X-Internal-Key`, and keeps it open. A producer never connects to a consumer.

Game serves `/events` as a plain WebSocket next to the client-facing `/game` Socket.IO namespace;
the two are unrelated.

| Consumer | Connects to |
|---|---|
| Player | Game |
| Game | Exam, World, Resource |
| Exam | — |
| World | Exam |
| Resource | Player, Game |
| Base | Player |
| Crafting | Player, Exam, World |
| Zombie | — |

### Envelope

Every event carries the same envelope. `type` is the event name, `<service>.<event>`, e.g.
`exam.completed`:

```json
{
  "eventId": "6f1c0c3e-…",
  "type": "exam.completed",
  "version": 1,
  "occurredAt": "2026-09-09T18:04:11Z",
  "payload": { }
}
```

### Frames

Messages on the socket are JSON text frames. The consumer sends:

```json
{ "op": "subscribe", "types": ["exam.completed"], "since": 1041 }
```

```json
{ "op": "ack", "seq": 1042 }
```

`types` lists the event names wanted. `since` is the `seq` of the last event the consumer has
processed (`0` on first connect); the producer replays everything after it, then streams live. The
producer sends:

```json
{ "op": "event", "seq": 1042, "event": { "eventId": "6f1c0c3e-…", "type": "exam.completed", "version": 1, "occurredAt": "2026-09-09T18:04:11Z", "payload": { } } }
```

`seq` is a per-producer counter that only increases. A consumer acks after it has handled the event
and persisted its own effect; it reconnects from its last acked `seq`.

### Delivery

- **At least once.** A producer writes the event to an outbox table in the same database
  transaction as the state change that caused it, so a crash never loses one. Events are pushed
  from the outbox and kept for 7 days. A consumer that has been down longer than that must
  resynchronise over REST.
- **Consumers deduplicate on `eventId`.** Replay after a reconnect can redeliver events that were
  handled but not yet acked; handling one twice must be a no-op.
- **Ordering** holds per producer (`seq`) and not across producers. Where it matters the consumer
  compares `occurredAt`.
- **Liveness.** Both sides send WebSocket pings every 30 s and drop the connection after two
  missed pongs. A consumer reconnects with exponential backoff, 1 s doubling to 30 s.

---

## Player Service

Identity, session, profile, friends, XP/levels, inventory, trading.

### Endpoints

<details>
<summary><b>POST</b> <code>/auth/register</code> — Create a player account</summary>

**Caller:** client · **Auth:** none · **Idempotent:** no

Creates the account with level 1 and 0 XP and an empty inventory, then publishes
`player.registered` so Base and Resource can create their per-player rows. Does not log the
player in — call `/auth/login` afterwards. Passwords are stored as bcrypt hashes.

**Request body**

```json
{ "username": "razvan", "password": "hunter2hunter2" }
```

| Field | Type | Rules |
|---|---|---|
| `username` | string | 3–20 chars, `[a-z0-9_]`, unique (case-insensitive) |
| `password` | string | 8–72 chars |

**Responses**

| Code | When |
|---|---|
| `201` | Account created |
| `409 USERNAME_TAKEN` | Username already exists |

```json
// 201
{ "id": 42, "username": "razvan", "createdAt": "2026-09-09T18:04:11Z" }
```

</details>

<details>
<summary><b>POST</b> <code>/auth/login</code> — Log in and receive the session cookie</summary>

**Caller:** client · **Auth:** none · **Idempotent:** no

Verifies credentials and sets the `access_token` cookie described in [Authentication](#authentication).
The response body carries only what the client needs to render the current player; the token
itself is never in the body.

**Request body**

```json
{ "username": "razvan", "password": "hunter2hunter2" }
```

**Responses**

| Code | When |
|---|---|
| `200` | Cookie set |
| `401 INVALID_CREDENTIALS` | Unknown username or wrong password (same error for both) |

```json
// 200   + Set-Cookie: access_token=…; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=86400
{ "id": 42, "username": "razvan" }
```

</details>

<details>
<summary><b>POST</b> <code>/auth/logout</code> — Clear the session cookie</summary>

**Caller:** client · **Auth:** cookie · **Idempotent:** yes (naturally)

Clears the cookie (`Max-Age=0`). Tokens are stateless, so an already-issued JWT stays valid until
`exp`; logout only removes it from the browser.

**Responses**

| Code | When |
|---|---|
| `204` | Cookie cleared |

</details>

<details>
<summary><b>GET</b> <code>/auth/jwks</code> — Public keys for JWT verification</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** —

Returns the current signing keys in JWK format. Services cache this for one hour and re-fetch on
an unknown `kid`. Key rotation publishes the new key here at least an hour before it is used.

**Responses**

```json
// 200
{ "keys": [ { "kty": "RSA", "kid": "2026-09", "use": "sig", "alg": "RS256", "n": "…", "e": "AQAB" } ] }
```

</details>

<details>
<summary><b>GET</b> <code>/players/me</code> — Current player's profile</summary>

**Caller:** client · **Auth:** cookie · **Idempotent:** —

Shorthand for `GET /players/{sub}`.

**Responses**

```json
// 200
{ "id": 42, "username": "razvan", "level": 7, "xp": 1420, "online": true }
```

</details>

<details>
<summary><b>GET</b> <code>/players/{id}</code> — A player's public profile</summary>

**Caller:** client, internal · **Auth:** cookie or `X-Internal-Key` · **Idempotent:** —

Any logged-in player can read any other player's profile (needed for friends lists, lobbies and
trading). `online` is maintained from `game.presence_changed`.

| Path param | Type |
|---|---|
| `id` | int |

**Responses**

| Code | When |
|---|---|
| `200` | Found |
| `404 PLAYER_NOT_FOUND` | No such player |

```json
// 200
{ "id": 42, "username": "razvan", "level": 7, "xp": 1420, "online": true }
```

</details>

<details>
<summary><b>GET</b> <code>/players/{id}/friends</code> — Friends list</summary>

**Caller:** client · **Auth:** cookie, `{id}` must equal `sub` · **Idempotent:** —

**Responses**

| Code | When |
|---|---|
| `200` | List (may be empty) |
| `404 PLAYER_NOT_FOUND` | No such player |

```json
// 200
[ { "id": 17, "username": "ana", "online": false }, { "id": 23, "username": "vlad", "online": true } ]
```

</details>

<details>
<summary><b>POST</b> <code>/players/{id}/friends</code> — Add a friend</summary>

**Caller:** client · **Auth:** cookie, `{id}` must equal `sub` · **Idempotent:** no (409 on repeat)

Friendship is symmetric: one call creates both directions. There is no request/accept step.

**Request body**

```json
{ "friendId": 17 }
```

**Responses**

| Code | When |
|---|---|
| `201` | Friendship created |
| `404 PLAYER_NOT_FOUND` | `friendId` does not exist |
| `409 ALREADY_FRIENDS` | Already friends |
| `422 SELF_FRIEND` | `friendId == id` |

```json
// 201
{ "id": 17, "username": "ana", "online": false }
```

</details>

<details>
<summary><b>DELETE</b> <code>/players/{id}/friends/{friendId}</code> — Remove a friend</summary>

**Caller:** client · **Auth:** cookie, `{id}` must equal `sub` · **Idempotent:** yes (naturally)

Removes both directions.

**Responses**

| Code | When |
|---|---|
| `204` | Removed |
| `404 NOT_FRIENDS` | No such friendship |

</details>

<details>
<summary><b>POST</b> <code>/players/{id}/xp</code> — Grant or take XP</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** yes

Applies `delta` to the player's XP (negative for a tourist-zombie steal), floors at 0, recomputes
the level and publishes `player.leveled_up` if the level went up. Level thresholds are Player
Service's own concern; callers only read the returned `level`. Called by Game (action rewards,
exam rewards, zombie steals).

**Request body**

```json
{ "delta": 50, "reason": "exam" }
```

| Field | Type | Rules |
|---|---|---|
| `delta` | int | ≠ 0 |
| `reason` | enum(`action`\|`exam`\|`zombie_steal`) | |

**Responses**

| Code | When |
|---|---|
| `200` | Applied |
| `404 PLAYER_NOT_FOUND` | No such player |

```json
// 200
{ "xp": 1470, "level": 7 }
```

</details>

<details>
<summary><b>GET</b> <code>/players/{id}/inventory</code> — Inventory contents</summary>

**Caller:** client, internal · **Auth:** cookie (`{id}` = `sub`) or `X-Internal-Key` · **Idempotent:** —

**Responses**

| Code | When |
|---|---|
| `200` | List (may be empty) |
| `404 PLAYER_NOT_FOUND` | No such player |

```json
// 200
[
  { "itemId": "coffee", "name": "Coffee", "type": "consumable", "quantity": 3 },
  { "itemId": "improvised_weapon", "name": "Improvised Weapon", "type": "equipment", "quantity": 1 }
]
```

</details>

<details>
<summary><b>POST</b> <code>/players/{id}/inventory/items</code> — Add items to inventory</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** yes

Upserts: adds `quantity` to the existing stack or creates it. Called by Crafting (crafted output)
and Base (Kiki rewards). Item metadata (`name`, `type`) comes from Player Service's item catalogue;
an unknown `itemId` is rejected.

**Request body**

```json
{ "itemId": "improvised_weapon", "quantity": 1 }
```

| Field | Type | Rules |
|---|---|---|
| `itemId` | string | Must exist in the item catalogue |
| `quantity` | int | ≥ 1 |

**Responses**

| Code | When |
|---|---|
| `200` | Stack updated |
| `404 PLAYER_NOT_FOUND` | No such player |
| `422 UNKNOWN_ITEM` | `itemId` not in catalogue |

```json
// 200
{ "itemId": "improvised_weapon", "name": "Improvised Weapon", "type": "equipment", "quantity": 2 }
```

</details>

<details>
<summary><b>POST</b> <code>/trades</code> — Transfer items to another player</summary>

**Caller:** client · **Auth:** cookie · **Idempotent:** yes

The sender is `sub` — never taken from the body. In a single DB transaction: lock both inventories,
verify the sender holds at least `quantity`, subtract, add to the receiver, write the trade record.
Players in different lobbies or sessions can trade; only the receiver's existence matters.

**Request body**

```json
{ "toPlayerId": 17, "itemId": "coffee", "quantity": 2 }
```

**Responses**

| Code | When |
|---|---|
| `201` | Trade completed |
| `404 PLAYER_NOT_FOUND` | Receiver does not exist |
| `409 INSUFFICIENT_QUANTITY` | Sender holds fewer than `quantity` |
| `422 SELF_TRADE` | Receiver is the sender |

```json
// 201
{ "tradeId": "9b2e…", "status": "completed" }
```

</details>

### Events

<details>
<summary><b>publishes</b> <code>player.registered</code> — A new account was created</summary>

Emitted once per successful `/auth/register`. Base creates the player's starting base (FAF Cab,
level 1); Resource creates zero balances.

```json
{ "playerId": 42, "username": "razvan" }
```

**Consumers:** Base, Resource

</details>

<details>
<summary><b>publishes</b> <code>player.leveled_up</code> — A player reached a new level</summary>

Emitted from `POST /players/{id}/xp` when the recomputed level is higher than before. One event
per level gained.

```json
{ "playerId": 42, "level": 8 }
```

**Consumers:** Crafting (recipe availability)

</details>

<details>
<summary><b>consumes</b> <code>game.presence_changed</code> — Sets the <code>online</code> flag</summary>

Game emits this when a player's client connects to or disconnects from the `/game` socket. Player
stores the latest value; out-of-order delivery is resolved by `occurredAt`.

</details>

### Schemas

<details>
<summary>Player, InventoryItem</summary>

```
Player        { id: int, username: string, level: int, xp: int, online: bool }
InventoryItem { itemId: string, name: string, type: enum(consumable|cosmetic|equipment), quantity: int }
```

</details>

---

## Game Service

Lobbies, sessions, the day/night cycle, timed actions, zombie encounters. Owns no persistent player
or world data — coordinates the others and pushes live state over WebSockets.

### Endpoints

<details>
<summary><b>POST</b> <code>/game/lobbies</code> — Create a lobby</summary>

**Caller:** client · **Auth:** cookie · **Idempotent:** no

Creates a lobby with the caller as host and first member. Max 4 players.

**Responses**

```json
// 201
{ "lobbyId": "c1d4…", "hostId": 42, "players": [42], "status": "waiting" }
```

</details>

<details>
<summary><b>POST</b> <code>/game/lobbies/{id}/players</code> — Join a lobby</summary>

**Caller:** client · **Auth:** cookie · **Idempotent:** yes (naturally — joining twice is a no-op)

**Responses**

| Code | When |
|---|---|
| `200` | Joined (or already a member) |
| `404 LOBBY_NOT_FOUND` | No such lobby |
| `409 LOBBY_FULL` | Already 4 players |
| `409 LOBBY_STARTED` | Session already running |

```json
// 200
{ "lobbyId": "c1d4…", "hostId": 42, "players": [42, 17], "status": "waiting" }
```

</details>

<details>
<summary><b>DELETE</b> <code>/game/lobbies/{id}/players/me</code> — Leave a lobby</summary>

**Caller:** client · **Auth:** cookie · **Idempotent:** yes (naturally)

If the host leaves, the earliest remaining member becomes host. An empty lobby is deleted.

**Responses**

| Code | When |
|---|---|
| `204` | Left |
| `404 LOBBY_NOT_FOUND` | No such lobby |

</details>

<details>
<summary><b>POST</b> <code>/game/lobbies/{id}/start</code> — Start a session</summary>

**Caller:** client · **Auth:** cookie, must be the host · **Idempotent:** no

Creates a session from the lobby. On start Game loads the map (`GET /world/rooms`,
`GET /world/spawn-points`) and zombie definitions (`GET /zombies`) into Redis, places every player
in FAF Cab, and begins the first **day** phase. Phases alternate on a fixed timer (day 10 min,
night 5 min); every switch emits `cycle:changed`.

**Responses**

| Code | When |
|---|---|
| `201` | Session created |
| `403 NOT_HOST` | Caller is not the host |
| `404 LOBBY_NOT_FOUND` | No such lobby |
| `409 LOBBY_STARTED` | Already started |

```json
// 201
{
  "sessionId": "7a90…", "phase": "day", "cycle": 1, "phaseEndsAt": "2026-09-09T18:14:11Z",
  "players": [
    { "playerId": 42, "roomId": 1, "status": "idle" },
    { "playerId": 17, "roomId": 1, "status": "idle" }
  ]
}
```

</details>

<details>
<summary><b>GET</b> <code>/game/sessions/{id}</code> — Session snapshot</summary>

**Caller:** client · **Auth:** cookie, must be a session member · **Idempotent:** —

The full current state — used on reconnect before subscribing to the WebSocket stream.

**Responses**

| Code | When |
|---|---|
| `200` | Found |
| `404 SESSION_NOT_FOUND` | No such session or not a member |

```json
// 200
{
  "sessionId": "7a90…", "phase": "night", "cycle": 3, "phaseEndsAt": "2026-09-09T18:44:11Z",
  "players": [
    { "playerId": 42, "roomId": 3, "status": "busy" },
    { "playerId": 17, "roomId": 1, "status": "in_exam" }
  ]
}
```

</details>

<details>
<summary><b>POST</b> <code>/game/sessions/{id}/actions</code> — Start a timed action</summary>

**Caller:** client · **Auth:** cookie, must be a session member · **Idempotent:** no

Starts a timed action for the calling player. The player must be `idle` and the target room must
be unlocked (`GET /world/rooms/{roomId}`). Progress streams over `action:progress`; completion
is announced by `action:completed`.

| Type | Duration | On completion |
|---|---|---|
| `chop_benches` | 600 s | Publishes `game.action_completed`; Resource awards wood |
| `scavenge` | 300 s | Publishes `game.action_completed`; Resource awards the room's node resource |
| `clear_room` | 180 s | Room is zombie-free for the rest of the cycle |
| `barricade_room` | 120 s | Game calls Base `POST /base/players/{id}/barricades` — if Base returns `409`, the action ends as `interrupted` |
| `repair_base` | 240 s | Game calls Base `POST /base/players/{id}/upgrades { facility: "homeroom" }` — same failure rule |

**Request body**

```json
{ "type": "scavenge", "roomId": 3 }
```

**Responses**

| Code | When |
|---|---|
| `202` | Action started |
| `404 SESSION_NOT_FOUND` | No such session or not a member |
| `409 PLAYER_BUSY` | Player already has an action or is in an exam |
| `422 ROOM_LOCKED` | Room's wing is not unlocked |
| `422 INVALID_ACTION_FOR_ROOM` | e.g. `scavenge` in a room with no resource node |

```json
// 202
{
  "actionId": "e3f1…", "playerId": 42, "type": "scavenge", "roomId": 3,
  "status": "in_progress", "durationSeconds": 300, "completesAt": "2026-09-09T18:09:11Z"
}
```

</details>

<details>
<summary><b>GET</b> <code>/game/sessions/{id}/actions/{actionId}</code> — Action status</summary>

**Caller:** client · **Auth:** cookie, must be a session member · **Idempotent:** —

**Responses**

| Code | When |
|---|---|
| `200` | Found |
| `404 ACTION_NOT_FOUND` | No such action in this session |

```json
// 200
{
  "actionId": "e3f1…", "playerId": 42, "type": "scavenge", "roomId": 3,
  "status": "completed", "durationSeconds": 300, "completesAt": "2026-09-09T18:09:11Z"
}
```

</details>

### WebSocket — namespace `/game`

Authenticated by the session cookie on handshake. A client joins one session at a time.

<details>
<summary><b>client → server</b> <code>session:join</code></summary>

Subscribes the socket to a session's events. Game emits `game.presence_changed { online: true }`
on the first join for that player and `{ online: false }` when the last socket disconnects.

```json
{ "sessionId": "7a90…" }
```

</details>

<details>
<summary><b>client → server</b> <code>session:leave</code></summary>

Unsubscribes. No payload.

</details>

<details>
<summary><b>server → client</b> <code>action:progress</code></summary>

Sent every 5 s while an action is running, to the acting player only.

```json
{ "actionId": "e3f1…", "progress": 0.42 }
```

</details>

<details>
<summary><b>server → client</b> <code>action:completed</code></summary>

Sent to the acting player. For gathering actions it is sent only after `resource.gathered`
arrives, so `gathered` reflects what Resource actually credited. `interrupted` actions carry
`reason`.

```json
{ "actionId": "e3f1…", "type": "scavenge", "status": "completed", "gathered": { "resourceType": "food", "amount": 12 } }
```

```json
{ "actionId": "b77c…", "type": "barricade_room", "status": "interrupted", "reason": "INSUFFICIENT_RESOURCES" }
```

</details>

<details>
<summary><b>server → client</b> <code>cycle:changed</code></summary>

Broadcast to the whole session on every phase switch.

```json
{ "sessionId": "7a90…", "phase": "night", "cycle": 3, "phaseEndsAt": "2026-09-09T18:44:11Z" }
```

</details>

<details>
<summary><b>server → client</b> <code>zombie:encounter</code></summary>

During night phases Game rolls encounters for players outside the base, using spawn points from
World and zombie stats (`perception`) from Zombie. Broadcast to the session.

```json
{ "encounterId": "a5c2…", "playerId": 42, "zombieId": 5, "zombieType": "professor" }
```

</details>

<details>
<summary><b>server → client</b> <code>zombie:attack</code></summary>

A tourist zombie hit the player. Game has already called Player `POST /players/{id}/xp` (negative
`delta`) and Resource `POST /resources/players/{id}/steal`; the payload reports what was actually
taken.

```json
{ "encounterId": "a5c2…", "playerId": 42, "damage": 8, "stolenXp": 25, "stolenResources": { "food": 4 } }
```

</details>

<details>
<summary><b>server → client</b> <code>exam:started</code></summary>

A professor zombie encounter: Game called Exam `POST /exams` and the player's status is now
`in_exam`. The client fetches the questions with `GET /exams/{examId}`.

```json
{ "encounterId": "a5c2…", "examId": 17 }
```

</details>

<details>
<summary><b>server → client</b> <code>world:wing_unlocked</code></summary>

Relayed from `world.wing_unlocked` to every active session.

```json
{ "wingId": 4, "name": "Math Wing" }
```

</details>

### Events

<details>
<summary><b>publishes</b> <code>game.action_completed</code> — A timed action ran to completion</summary>

Emitted when an action's timer expires without interruption. `nodeId` is set for gathering
actions in rooms with a resource node.

```json
{ "actionId": "e3f1…", "sessionId": "7a90…", "playerId": 42, "type": "scavenge", "roomId": 3, "nodeId": 12, "completedAt": "2026-09-09T18:09:11Z" }
```

**Consumers:** Resource

</details>

<details>
<summary><b>publishes</b> <code>game.presence_changed</code> — Player connected or disconnected</summary>

```json
{ "playerId": 42, "online": true }
```

**Consumers:** Player

</details>

<details>
<summary><b>consumes</b> <code>resource.gathered</code>, <code>exam.completed</code>, <code>world.wing_unlocked</code></summary>

- `resource.gathered` → emits `action:completed` with the credited amount.
- `exam.completed` → ends the encounter, sets the player back to `idle`, calls Player
  `POST /players/{id}/xp` with the exam reward if `passed`.
- `world.wing_unlocked` → marks the rooms unlocked in Redis, emits `world:wing_unlocked`.

</details>

### Schemas

<details>
<summary>ActionType, Lobby, Session, Action</summary>

```
ActionType { chop_benches | scavenge | clear_room | barricade_room | repair_base }
Lobby      { lobbyId: uuid, hostId: int, players: [int], status: enum(waiting|started) }
Session    { sessionId: uuid, phase: enum(day|night), cycle: int, phaseEndsAt: datetime,
             players: [{ playerId: int, roomId: int, status: enum(idle|busy|in_exam) }] }
Action     { actionId: uuid, playerId: int, type: ActionType, roomId: int,
             status: enum(in_progress|completed|interrupted), durationSeconds: int, completesAt: datetime }
```

</details>

---

## Exam Service

Exams, grading, per-player academic history and achievements.

**Current implementation:** until Player and Zombie are running, Exam can use stand-ins, all on by
default in compose: `AUTH_MODE=mock` reads the acting player from the `X-Player-Id` header instead
of the cookie, `PLAYER_CLIENT=mock` accepts every player id, and `ZOMBIE_CLIENT=mock` serves
built-in professor zombies. `jwks` / `http` switch each one to the real service.

### Endpoints

<details>
<summary><b>POST</b> <code>/exams</code> — Create an exam for an encounter</summary>

**Caller:** internal (Game) · **Auth:** `X-Internal-Key` · **Idempotent:** yes

Picks the subject from the professor zombie (`GET /zombies/{zombieId}` → `subject`), draws 5
questions from the static bank for that subject, and sets a 120 s deadline. The `encounterId` is
stored so a retried call for the same encounter returns the same exam.

**Request body**

```json
{ "playerId": 42, "zombieId": 5, "encounterId": "a5c2…" }
```

**Responses**

| Code | When |
|---|---|
| `201` | Exam created |
| `404 PLAYER_NOT_FOUND` | No such player |
| `422 NOT_A_PROFESSOR` | Zombie has no `subject` |

```json
// 201
{
  "examId": 17, "playerId": 42, "subject": "math", "expiresAt": "2026-09-09T18:06:11Z",
  "questions": [
    { "questionId": 101, "text": "d/dx of x^2 ?", "options": ["x", "2x", "x^2", "2"] }
  ]
}
```

</details>

<details>
<summary><b>GET</b> <code>/exams/{id}</code> — Fetch an exam's questions</summary>

**Caller:** client · **Auth:** cookie, must be the exam's player · **Idempotent:** —

Correct answers are never included.

**Responses**

| Code | When |
|---|---|
| `200` | Found |
| `404 EXAM_NOT_FOUND` | No such exam or not yours |

```json
// 200
{
  "examId": 17, "playerId": 42, "subject": "math", "expiresAt": "2026-09-09T18:06:11Z",
  "questions": [ { "questionId": 101, "text": "d/dx of x^2 ?", "options": ["x", "2x", "x^2", "2"] } ]
}
```

</details>

<details>
<summary><b>POST</b> <code>/exams/{id}/answers</code> — Submit answers</summary>

**Caller:** client · **Auth:** cookie, must be the exam's player · **Idempotent:** no (409 on repeat)

Grades the exam: `grade = round(correct / total × 10)`, `passed = grade ≥ 5`. Records the result,
checks achievement rules (e.g. all `math` exams passed → `survived_the_pumpkin`), then publishes
`exam.completed`. A submission after `expiresAt` is graded as failed with `grade = 1`.

**Request body**

```json
{ "answers": [ { "questionId": 101, "option": 1 }, { "questionId": 102, "option": 3 } ] }
```

| Field | Type | Rules |
|---|---|---|
| `answers[].questionId` | int | Must belong to this exam |
| `answers[].option` | int | Index into `options` |

**Responses**

| Code | When |
|---|---|
| `200` | Graded |
| `404 EXAM_NOT_FOUND` | No such exam or not yours |
| `409 ALREADY_SUBMITTED` | Already graded |

```json
// 200
{ "examId": 17, "subject": "math", "passed": true, "grade": 8, "correct": 4, "total": 5, "takenAt": "2026-09-09T18:04:11Z" }
```

</details>

<details>
<summary><b>GET</b> <code>/exams/players/{id}</code> — A player's exam history</summary>

**Caller:** client · **Auth:** cookie, `{id}` must equal `sub` · **Idempotent:** —

**Responses**

```json
// 200
[ { "examId": 17, "subject": "math", "passed": true, "grade": 8, "correct": 4, "total": 5, "takenAt": "2026-09-09T18:04:11Z" } ]
```

</details>

<details>
<summary><b>GET</b> <code>/exams/players/{id}/achievements</code> — Unlocked achievements</summary>

**Caller:** client · **Auth:** cookie, `{id}` must equal `sub` · **Idempotent:** —

**Responses**

```json
// 200
[ { "id": "survived_the_pumpkin", "name": "Survived the Pumpkin", "unlockedAt": "2026-09-09T18:04:11Z" } ]
```

</details>

<details>
<summary><b>GET</b> <code>/exams/questions</code> — List the question bank</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** —

| Query param | Type | Effect |
|---|---|---|
| `subject` | string? | Only questions for this subject |

**Responses**

```json
// 200 — includes the correct answer, so it is never exposed to clients
[ { "questionId": 1, "subject": "math", "text": "d/dx of x^2 ?", "options": ["x", "2x", "x^2", "2"], "correctOption": 1 } ]
```

</details>

<details>
<summary><b>GET</b> <code>/exams/questions/{id}</code> — One question</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** —

**Responses**

| Code | When |
|---|---|
| `200` | Found; body is the `Question` |
| `404 QUESTION_NOT_FOUND` | No such question |

</details>

<details>
<summary><b>POST</b> <code>/exams/questions</code> — Add a question to the bank</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** —

**Request body**

```json
{ "subject": "math", "text": "12 / 4 = ?", "options": ["2", "3", "4", "6"], "correctOption": 1 }
```

| Field | Type | Rules |
|---|---|---|
| `subject` | string | Required |
| `text` | string | Required, ≤ 500 chars |
| `options` | [string] | 2–6 non-empty options |
| `correctOption` | int | Index into `options` |

**Responses**

| Code | When |
|---|---|
| `201` | Created; body is the `Question` |

</details>

<details>
<summary><b>PUT</b> <code>/exams/questions/{id}</code> — Replace a question</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** yes (naturally)

Same body and rules as create. Exams already drawn keep a snapshot of their questions, so editing
the bank never changes an exam in progress or its grade.

**Responses**

| Code | When |
|---|---|
| `200` | Updated; body is the `Question` |
| `404 QUESTION_NOT_FOUND` | No such question |

</details>

<details>
<summary><b>DELETE</b> <code>/exams/questions/{id}</code> — Remove a question</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** —

**Responses**

| Code | When |
|---|---|
| `204` | Deleted |
| `404 QUESTION_NOT_FOUND` | No such question |

</details>

### Events

<details>
<summary><b>publishes</b> <code>exam.completed</code> — An exam was graded</summary>

Emitted for every graded exam, pass or fail. World reacts only when `passed` is true.

```json
{ "examId": 17, "playerId": 42, "subject": "math", "passed": true, "grade": 8 }
```

**Consumers:** World, Game, Crafting

</details>

### Schemas

<details>
<summary>Exam, ExamResult</summary>

```
Exam       { examId: int, playerId: int, subject: string, expiresAt: datetime,
             questions: [{ questionId: int, text: string, options: [string] }] }
ExamResult { examId: int, subject: string, passed: bool, grade: int, correct: int, total: int, takenAt: datetime }
Question   { questionId: int, subject: string, text: string, options: [string], correctOption: int }   // internal only
```

</details>

---

## World Service

The campus: wings, rooms, resource nodes, zombie spawn points. Geography only — what players build
on it belongs to Base.

**Current implementation:** until JWT verification is wired in (`AUTH_MODE=jwks`), World reads the
acting player from the `X-Player-Id` header instead of the cookie. It consumes Exam's WebSocket
stream, and also accepts events over HTTP at `POST /world/internal/events`.

### Endpoints

<details>
<summary><b>GET</b> <code>/world/rooms</code> — List rooms</summary>

**Caller:** client, internal · **Auth:** cookie or `X-Internal-Key` · **Idempotent:** —

| Query param | Type | Effect |
|---|---|---|
| `type` | RoomType? | Filter by room type |
| `wingId` | int? | Filter by wing |
| `unlocked` | bool? | Filter by wing unlock state |

**Responses**

```json
// 200
[
  { "roomId": 1, "name": "FAF Cab", "type": "fafcab", "wingId": 1, "unlocked": true, "resourceNode": null },
  { "roomId": 3, "name": "Lab 204", "type": "laboratory", "wingId": 1, "unlocked": true,
    "resourceNode": { "nodeId": 12, "resourceType": "metal" } }
]
```

</details>

<details>
<summary><b>GET</b> <code>/world/rooms/{id}</code> — One room</summary>

**Caller:** client, internal · **Auth:** cookie or `X-Internal-Key` · **Idempotent:** —

**Responses**

| Code | When |
|---|---|
| `200` | Found |
| `404 ROOM_NOT_FOUND` | No such room |

```json
// 200
{ "roomId": 3, "name": "Lab 204", "type": "laboratory", "wingId": 1, "unlocked": true,
  "resourceNode": { "nodeId": 12, "resourceType": "metal" } }
```

</details>

<details>
<summary><b>GET</b> <code>/world/wings</code> — List wings</summary>

**Caller:** client, internal · **Auth:** cookie or `X-Internal-Key` · **Idempotent:** —

**Responses**

```json
// 200
[
  { "wingId": 1, "name": "Main Building", "unlocked": true, "unlockedBySubject": null },
  { "wingId": 4, "name": "Math Wing", "unlocked": false, "unlockedBySubject": "math" }
]
```

</details>

<details>
<summary><b>GET</b> <code>/world/spawn-points</code> — Zombie spawn points</summary>

**Caller:** internal (Game) · **Auth:** `X-Internal-Key` · **Idempotent:** —

| Query param | Type | Effect |
|---|---|---|
| `roomId` | int? | Only spawn points in this room |

**Responses**

```json
// 200
[ { "pointId": 7, "roomId": 3, "zombieTypes": ["professor", "tourist"] } ]
```

</details>

<details>
<summary><b>GET</b> <code>/world/wings/{id}</code> — One wing</summary>

**Caller:** client, internal · **Auth:** cookie or `X-Internal-Key` · **Idempotent:** —

**Responses**

| Code | When |
|---|---|
| `200` | Found; body is the `Wing` |
| `404 WING_NOT_FOUND` | No such wing |

</details>

<details>
<summary><b>POST</b> <code>/world/wings</code> — Create a wing</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** —

**Request body**

```json
{ "name": "Chemistry Wing", "unlocked": false, "unlockedBySubject": "chemistry" }
```

| Field | Type | Rules |
|---|---|---|
| `name` | string | Required, unique |
| `unlocked` | bool? | Default `false` |
| `unlockedBySubject` | string? | Subject whose passed exam unlocks the wing; `null` for none |

**Responses**

| Code | When |
|---|---|
| `201` | Created; body is the `Wing` |
| `409 WING_NAME_TAKEN` | A wing with that name exists |

</details>

<details>
<summary><b>PUT</b> <code>/world/wings/{id}</code> — Replace a wing</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** yes (naturally)

Same body and rules as create. Changing `unlocked` from `false` to `true` publishes
`world.wing_unlocked`, as an exam pass would.

**Responses**

| Code | When |
|---|---|
| `200` | Updated; body is the `Wing` |
| `404 WING_NOT_FOUND` | No such wing |
| `409 WING_NAME_TAKEN` | Another wing has that name |

</details>

<details>
<summary><b>DELETE</b> <code>/world/wings/{id}</code> — Delete a wing</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** —

**Responses**

| Code | When |
|---|---|
| `204` | Deleted |
| `404 WING_NOT_FOUND` | No such wing |
| `409 WING_NOT_EMPTY` | The wing still has rooms |

</details>

<details>
<summary><b>POST</b> <code>/world/rooms</code> — Create a room</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** —

**Request body**

```json
{ "name": "Chem Lab", "type": "laboratory", "wingId": 2, "resourceNode": { "resourceType": "metal" } }
```

| Field | Type | Rules |
|---|---|---|
| `name` | string | Required |
| `type` | RoomType | Required |
| `wingId` | int | Must be an existing wing |
| `resourceNode` | `{ resourceType }`? | Omit or `null` for a room without a gatherable node |

**Responses**

| Code | When |
|---|---|
| `201` | Created; body is the `Room` |
| `404 WING_NOT_FOUND` | No such wing |

</details>

<details>
<summary><b>PUT</b> <code>/world/rooms/{id}</code> — Replace a room</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** yes (naturally)

Same body and rules as create; omitting `resourceNode` removes the room's node.

**Responses**

| Code | When |
|---|---|
| `200` | Updated; body is the `Room` |
| `404 ROOM_NOT_FOUND` | No such room |
| `404 WING_NOT_FOUND` | No such wing |

</details>

<details>
<summary><b>DELETE</b> <code>/world/rooms/{id}</code> — Delete a room</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** —

Also deletes the room's resource node and spawn points.

**Responses**

| Code | When |
|---|---|
| `204` | Deleted |
| `404 ROOM_NOT_FOUND` | No such room |

</details>

<details>
<summary><b>GET</b> <code>/world/spawn-points/{id}</code> — One spawn point</summary>

**Caller:** internal (Game) · **Auth:** `X-Internal-Key` · **Idempotent:** —

**Responses**

| Code | When |
|---|---|
| `200` | Found; body is the `SpawnPoint` |
| `404 SPAWN_POINT_NOT_FOUND` | No such spawn point |

</details>

<details>
<summary><b>POST</b> <code>/world/spawn-points</code> — Create a spawn point</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** —

**Request body**

```json
{ "roomId": 3, "zombieTypes": ["professor", "tourist"] }
```

| Field | Type | Rules |
|---|---|---|
| `roomId` | int | Must be an existing room |
| `zombieTypes` | [ZombieType] | Non-empty, no duplicates |

**Responses**

| Code | When |
|---|---|
| `201` | Created; body is the `SpawnPoint` |
| `404 ROOM_NOT_FOUND` | No such room |

</details>

<details>
<summary><b>PUT</b> <code>/world/spawn-points/{id}</code> — Replace a spawn point</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** yes (naturally)

Same body and rules as create.

**Responses**

| Code | When |
|---|---|
| `200` | Updated; body is the `SpawnPoint` |
| `404 SPAWN_POINT_NOT_FOUND` | No such spawn point |
| `404 ROOM_NOT_FOUND` | No such room |

</details>

<details>
<summary><b>DELETE</b> <code>/world/spawn-points/{id}</code> — Delete a spawn point</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** —

**Responses**

| Code | When |
|---|---|
| `204` | Deleted |
| `404 SPAWN_POINT_NOT_FOUND` | No such spawn point |

</details>

<details>
<summary><b>POST</b> <code>/world/internal/events</code> — Receive a service event</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** yes (deduplicated on `eventId`)

Takes one `exam.completed` event in the standard [envelope](#envelope) and applies it exactly as
the WebSocket consumer does. Other event types are rejected with `400 VALIDATION_ERROR`.

**Responses**

```json
// 200 — duplicate is true when the eventId was seen before
{ "eventId": "6f1c0c3e-…", "duplicate": false }
```

</details>

### Events

<details>
<summary><b>consumes</b> <code>exam.completed</code> — Unlocks a wing on a pass</summary>

If `passed` is true and a wing has `unlockedBySubject == subject` and is still locked, it is
unlocked and `world.wing_unlocked` is published. Already-unlocked wings make the event a no-op.

</details>

<details>
<summary><b>publishes</b> <code>world.wing_unlocked</code> — A wing became reachable</summary>

```json
{ "wingId": 4, "name": "Math Wing", "roomIds": [14, 15, 16] }
```

**Consumers:** Game, Crafting

</details>

### Schemas

<details>
<summary>RoomType, Room, Wing</summary>

```
RoomType { laboratory | library | canteen | classroom | corridor | fafcab }
Room     { roomId: int, name: string, type: RoomType, wingId: int, unlocked: bool,
           resourceNode: { nodeId: int, resourceType: string }? }
Wing     { wingId: int, name: string, unlocked: bool, unlockedBySubject: string? }
SpawnPoint { pointId: int, roomId: int, zombieTypes: [ZombieType] }
```

</details>

---

## Zombie Service

Zombie definitions: types, stats, abilities, sprites. Read-only at runtime.

**Current implementation:** until Player's JWKS is wired in, the `access_token` cookie is decoded
but its signature is not verified (`sub`/`exp` are still checked). Definitions start empty; add
them with `POST /zombies`.

### Endpoints

<details>
<summary><b>GET</b> <code>/zombies</code> — List zombie definitions</summary>

**Caller:** internal (Game) · **Auth:** `X-Internal-Key` · **Idempotent:** —

| Query param | Type | Effect |
|---|---|---|
| `type` | ZombieType? | Filter by type |

**Responses**

```json
// 200
[
  { "zombieId": 5, "type": "professor", "name": "Prof. Grosu", "subject": "math", "spriteUrl": "/sprites/prof_grosu.png",
    "stats": { "health": 120, "speed": 1, "attack": 8, "perception": 3 }, "abilities": ["administer_exam"] },
  { "zombieId": 9, "type": "tourist", "name": "Lost Erasmus", "subject": null, "spriteUrl": "/sprites/tourist.png",
    "stats": { "health": 60, "speed": 3, "attack": 5, "perception": 5 }, "abilities": ["steal_xp", "steal_resources", "sprint"] }
]
```

</details>

<details>
<summary><b>GET</b> <code>/zombies/{id}</code> — One zombie definition</summary>

**Caller:** client, internal · **Auth:** cookie or `X-Internal-Key` · **Idempotent:** —

**Responses**

| Code | When |
|---|---|
| `200` | Found |
| `404 ZOMBIE_NOT_FOUND` | No such zombie |

```json
// 200
{ "zombieId": 5, "type": "professor", "name": "Prof. Grosu", "subject": "math", "spriteUrl": "/sprites/prof_grosu.png",
  "stats": { "health": 120, "speed": 1, "attack": 8, "perception": 3 }, "abilities": ["administer_exam"] }
```

</details>

<details>
<summary><b>POST</b> <code>/zombies</code> · <b>PATCH</b> <code>/zombies/{id}</code> · <b>DELETE</b> <code>/zombies/{id}</code> — Manage definitions</summary>

**Caller:** internal (admin) · **Auth:** `X-Internal-Key` · **Idempotent:** —

`POST` takes a full `Zombie` without `zombieId` and returns `201` with it; `PATCH` takes any subset
of its fields and returns `200`; `DELETE` returns `204`. `404 ZOMBIE_NOT_FOUND` for an unknown id.

```json
{ "type": "tourist", "name": "Lost Erasmus", "subject": null, "spriteUrl": "/sprites/tourist.png",
  "stats": { "health": 60, "speed": 3, "attack": 5, "perception": 5 }, "abilities": ["steal_xp", "steal_resources", "sprint"] }
```

</details>

### Schemas

<details>
<summary>ZombieType, Zombie</summary>

```
ZombieType { professor | tourist | dean | janitor }
Zombie     { zombieId: int, type: ZombieType, name: string, subject: string?, spriteUrl: string,
             stats: { health: int, speed: int, attack: int, perception: int },
             abilities: [enum(administer_exam|steal_xp|steal_resources|sprint)] }
```

`subject` is set only for `professor`.

</details>

---

## Resource Service

The resource economy: per-player balances, gathering, spending, a ledger of every change.

Spending is two-phase so a caller that fails after spending can undo it:
**reserve → do the work → commit** (or release). Reservations not committed within 60 s are
released automatically.

**Current implementation:** until Player's JWKS is wired in, the `access_token` cookie is decoded
but its signature is not verified. Resource serves `resource.gathered` on `ws://resource:8086/events`
and consumes Player's and Game's streams when `PLAYER_EVENTS_URL` / `GAME_EVENTS_URL` are set;
until then it also accepts events over HTTP at `POST /resources/internal/events` (same handlers,
same `eventId` deduplication). Room → node resource types come from World's
`GET /world/rooms/{id}` when `WORLD_SERVICE_URL` is set, otherwise from a built-in copy of the
example rooms.

### Endpoints

<details>
<summary><b>GET</b> <code>/resources/players/{id}</code> — Current balances</summary>

**Caller:** client, internal · **Auth:** cookie (`{id}` = `sub`) or `X-Internal-Key` · **Idempotent:** —

Balances exclude amounts held by open reservations.

**Responses**

| Code | When |
|---|---|
| `200` | Found |
| `404 PLAYER_NOT_FOUND` | No balances for this player (never registered) |

```json
// 200
{ "playerId": 42, "balances": { "wood": 12, "metal": 4, "paper": 7, "food": 20, "textbooks": 2, "chemicals": 0, "electronics": 0 } }
```

</details>

<details>
<summary><b>GET</b> <code>/resources/players/{id}/ledger</code> — Change history</summary>

**Caller:** client · **Auth:** cookie, `{id}` must equal `sub` · **Idempotent:** —

Newest first. `nodeId` records where a resource was gathered.

| Query param | Type | Default |
|---|---|---|
| `limit` | int | 50, max 200 |
| `before` | datetime? | Cursor |

**Responses**

```json
// 200
[
  { "entryId": "d0a1…", "kind": "gathered", "resourceType": "food", "amount": 12, "nodeId": 12, "actionId": "e3f1…", "reservationId": null, "encounterId": null, "at": "2026-09-09T18:09:11Z" },
  { "entryId": "c9f0…", "kind": "spent", "resourceType": "wood", "amount": -10, "nodeId": null, "actionId": null, "reservationId": "5b3e…", "encounterId": null, "at": "2026-09-09T18:01:40Z" }
]
```

</details>

<details>
<summary><b>POST</b> <code>/resources/players/{id}/reservations</code> — Reserve resources for a spend</summary>

**Caller:** internal (Base, Crafting) · **Auth:** `X-Internal-Key` · **Idempotent:** yes

Atomically checks every requested resource against the free balance and holds the amounts. Held
amounts are invisible to other reservations and to `GET /resources/players/{id}`. Either all
resources are reserved or none.

**Request body**

```json
{ "resources": { "wood": 10, "metal": 5 } }
```

| Field | Type | Rules |
|---|---|---|
| `resources` | map<string,int> | Non-empty, every amount ≥ 1 |

**Responses**

| Code | When |
|---|---|
| `201` | Reserved |
| `404 PLAYER_NOT_FOUND` | No balances for this player |
| `409 INSUFFICIENT_RESOURCES` | At least one resource short — `message` says which |

```json
// 201
{ "reservationId": "5b3e…", "expiresAt": "2026-09-09T18:02:40Z" }
```

</details>

<details>
<summary><b>POST</b> <code>/resources/reservations/{id}/commit</code> — Finalize a spend</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** yes (naturally — committing twice returns the same result)

Deducts the reserved amounts permanently and writes `spent` ledger entries.

**Responses**

| Code | When |
|---|---|
| `200` | Committed (or already committed) |
| `404 RESERVATION_NOT_FOUND` | No such reservation |
| `409 RESERVATION_RELEASED` | Already released through `DELETE`; reserve again |
| `410 RESERVATION_EXPIRED` | Auto-released after 60 s; reserve again |

```json
// 200
{ "playerId": 42, "balances": { "wood": 2, "metal": 0, "paper": 7, "food": 20, "textbooks": 2, "chemicals": 0, "electronics": 0 } }
```

</details>

<details>
<summary><b>DELETE</b> <code>/resources/reservations/{id}</code> — Release a reservation</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** yes (naturally)

Returns held amounts to the free balance. Used by Base/Crafting when the step after reserving fails.

**Responses**

| Code | When |
|---|---|
| `204` | Released (or already released/expired) |
| `404 RESERVATION_NOT_FOUND` | No such reservation |
| `409 ALREADY_COMMITTED` | Cannot release a committed reservation |

</details>

<details>
<summary><b>POST</b> <code>/resources/players/{id}/steal</code> — Tourist zombie theft</summary>

**Caller:** internal (Game) · **Auth:** `X-Internal-Key` · **Idempotent:** yes

Takes `min(requested, free balance)` per resource; never fails for insufficient balance. Writes
`stolen` ledger entries. `encounterId` is recorded on each ledger entry.

**Request body**

```json
{ "resources": { "food": 5, "wood": 3 }, "encounterId": "a5c2…" }
```

| Field | Type | Rules |
|---|---|---|
| `resources` | map<string,int> | Non-empty, every amount ≥ 1 |
| `encounterId` | string | Required; the Game encounter that caused the theft |

**Responses**

| Code | When |
|---|---|
| `200` | Applied |
| `404 PLAYER_NOT_FOUND` | No balances for this player |

```json
// 200
{ "taken": { "food": 4, "wood": 3 } }
```

</details>

<details>
<summary><b>POST</b> <code>/resources/internal/events</code> — Deliver an event over HTTP</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** yes (deduplicated on `eventId`)

Accepts a full event envelope (`player.registered` or `game.action_completed`) and runs the same
handler as the WebSocket consumer. `GET /resources/internal/events?since=<seq>` lists the events
Resource has produced.

**Responses**

| Code | When |
|---|---|
| `202` | `{ "eventId", "status": "handled" \| "duplicate" \| "ignored" }` |
| `400 VALIDATION_ERROR` | Malformed envelope or payload |

</details>

<details>
<summary>Admin CRUD — balances, ledger entries, reservations</summary>

**Caller:** internal (admin, testing) · **Auth:** `X-Internal-Key` · **Idempotent:** —

Raw rows, bypassing the economy rules. Not for use by other services.

| Resource | Routes |
|---|---|
| Balances | `POST`/`GET /resources/balances`, `GET`/`PATCH`/`DELETE /resources/balances/{id}`, `GET /resources/players/{id}/balances` |
| Ledger | `POST`/`GET /resources/ledger`, `GET`/`PATCH`/`DELETE /resources/ledger/{id}` |
| Reservations | `GET /resources/reservations`, `GET`/`PATCH /resources/reservations/{id}`, `GET /resources/players/{id}/reservations` |

</details>

### Events

<details>
<summary><b>consumes</b> <code>game.action_completed</code> — Credits gathered resources</summary>

Only for `chop_benches` (always wood) and `scavenge` (the node's `resourceType`; ignored if
`nodeId` is null). Yield is random in 5–15. Applied at most once per `actionId`; a redelivered
event is a no-op. Publishes `resource.gathered` after crediting.

</details>

<details>
<summary><b>consumes</b> <code>player.registered</code> — Creates zero balances</summary>

</details>

<details>
<summary><b>publishes</b> <code>resource.gathered</code> — Resources were credited for an action</summary>

```json
{ "actionId": "e3f1…", "playerId": 42, "resourceType": "food", "amount": 12, "nodeId": 12 }
```

**Consumers:** Game

</details>

### Schemas

<details>
<summary>LedgerEntry</summary>

```
LedgerEntry { entryId: uuid, kind: enum(gathered|spent|stolen), resourceType: string, amount: int,
              nodeId: int?, actionId: uuid?, reservationId: uuid?, encounterId: string?, at: datetime }
```

Resource types are open strings; the current set is `wood`, `metal`, `paper`, `food`, `textbooks`,
`chemicals`, `electronics`.

</details>

---

## Base Service

What players have built: base level, facilities, barricades, storage, Kiki.

Every spend follows **reserve (Resource) → apply locally → commit (Resource)**; a failed local
write releases the reservation.

**Costs** (Base's own table):

| Spend | Cost |
|---|---|
| Facility upgrade | per current level (a new facility costs one level): storage `10 wood + 4 metal`, kitchen `8 wood + 2 metal`, workshop `6 wood + 6 metal`, homeroom `12 wood + 4 paper` |
| Barricade | per level being built: `3 wood + 1 metal` |
| Kiki | the `food` sent in the request |

Base `level` is its highest facility level; `storageCapacity` is 100 per storage level. A new base
has only `storage` at level 1.

**Current implementation:** until JWT verification is added, Base reads the acting player from the
`X-Player-Id` header instead of the cookie, and receives events over HTTP at
`POST /base/internal/events` instead of a WebSocket connection to Player.

### Endpoints

<details>
<summary><b>GET</b> <code>/base/players/{id}</code> — Base state</summary>

**Caller:** client · **Auth:** cookie, `{id}` must equal `sub` · **Idempotent:** —

**Responses**

| Code | When |
|---|---|
| `200` | Found |
| `404 BASE_NOT_FOUND` | Player never registered |

```json
// 200
{
  "baseId": 8, "playerId": 42, "level": 2, "storageCapacity": 200,
  "facilities": [ { "type": "storage", "level": 2 }, { "type": "kitchen", "level": 1 } ],
  "barricades": [ { "roomId": 1, "level": 3 }, { "roomId": 2, "level": 1 } ]
}
```

</details>

<details>
<summary><b>POST</b> <code>/base/players/{id}/upgrades</code> — Upgrade a facility</summary>

**Caller:** client, internal (Game, for `repair_base`) · **Auth:** cookie (`{id}` = `sub`) or `X-Internal-Key` · **Idempotent:** yes

Cost per facility and level is Base's own table; the response reports what was charged. Max level 5.

**Request body**

```json
{ "facility": "storage" }
```

**Responses**

| Code | When |
|---|---|
| `200` | Upgraded |
| `404 BASE_NOT_FOUND` | Player never registered |
| `409 INSUFFICIENT_RESOURCES` | Resource reservation refused |
| `422 MAX_LEVEL` | Already level 5 |

```json
// 200
{ "facility": "storage", "level": 3, "spent": { "wood": 20, "metal": 8 } }
```

</details>

<details>
<summary><b>POST</b> <code>/base/players/{id}/barricades</code> — Build or reinforce a barricade</summary>

**Caller:** client, internal (Game, for `barricade_room`) · **Auth:** cookie (`{id}` = `sub`) or `X-Internal-Key` · **Idempotent:** yes

Checks the room with World (`GET /world/rooms/{roomId}`, must be `unlocked`), then reserve →
increment level → commit. Max level 3.

**Request body**

```json
{ "roomId": 2 }
```

**Responses**

| Code | When |
|---|---|
| `200` | Built / reinforced |
| `404 BASE_NOT_FOUND` | Player never registered |
| `409 INSUFFICIENT_RESOURCES` | Resource reservation refused |
| `422 ROOM_LOCKED` | Room's wing is locked |
| `422 MAX_LEVEL` | Already level 3 |

```json
// 200
{ "roomId": 2, "level": 2, "spent": { "wood": 6, "metal": 2 } }
```

</details>

<details>
<summary><b>POST</b> <code>/base/players/{id}/kiki/feed</code> — Feed Kiki for a random reward</summary>

**Caller:** client · **Auth:** cookie, `{id}` must equal `sub` · **Idempotent:** yes

Spends the given food via Resource, rolls a reward (30 % chance), and if one drops delivers it with
Player `POST /players/{id}/inventory/items`. If that delivery fails, the reservation is released
and `409 REWARD_DELIVERY_FAILED` is returned so the client can retry with the same key.

**Request body**

```json
{ "resourceType": "food", "amount": 3 }
```

**Responses**

| Code | When |
|---|---|
| `200` | Fed; `reward` is null if nothing dropped |
| `409 INSUFFICIENT_RESOURCES` | Not enough food |
| `409 REWARD_DELIVERY_FAILED` | Player Service unavailable; nothing was spent |
| `422 KIKI_NOT_HUNGRY` | Fed within the last 10 minutes |

```json
// 200
{ "spent": { "food": 3 }, "reward": { "itemId": "energy_drink", "quantity": 1 } }
```

</details>

<details>
<summary><b>GET</b> <code>/base/players</code> — List all bases</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** —

**Responses**

```json
// 200
[ { "baseId": 8, "playerId": 42, "level": 2, "storageCapacity": 200, "facilities": [ … ], "barricades": [ … ] } ]
```

</details>

<details>
<summary><b>POST</b> <code>/base/players</code> — Create a starting base</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** yes (naturally)

Does the same as consuming `player.registered`. Creating a base that already exists returns it
unchanged.

**Request body**

```json
{ "playerId": 42 }
```

**Responses**

| Code | When |
|---|---|
| `201` | Created |
| `200` | Already existed |

Body: the `Base`.

</details>

<details>
<summary><b>DELETE</b> <code>/base/players/{id}</code> — Delete a player's base</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** —

**Responses**

| Code | When |
|---|---|
| `204` | Deleted, with its facilities and barricades |
| `404 BASE_NOT_FOUND` | No base for this player |

</details>

<details>
<summary><b>POST</b> <code>/base/internal/events</code> — Receive a service event</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** yes (deduplicated on `eventId`)

Takes one event in the standard [envelope](#envelope). Stands in for the WebSocket consumer until
it is built; both apply events the same way.

**Responses**

```json
// 200 — status is processed, duplicate (eventId seen before) or ignored (type Base does not consume)
{ "eventId": "6f1c0c3e-…", "status": "processed" }
```

</details>

### Events

<details>
<summary><b>consumes</b> <code>player.registered</code> — Creates the starting base</summary>

FAF Cab (`roomId` 1) at level 1, storage 100, no barricades.

</details>

### Schemas

<details>
<summary>Facility, Base</summary>

```
Facility { storage | kitchen | workshop | homeroom }
Base     { baseId: int, playerId: int, level: int, storageCapacity: int,
           facilities: [{ type: Facility, level: int }],
           barricades: [{ roomId: int, level: int }] }
```

</details>

---

## Crafting Service

Recipes and crafting. Output items are delivered into the Player Service inventory.

A player's level for `available` is the higher of Player's `GET /players/{id}` and the last
`player.leveled_up` seen. Unlocked wings are global: once World reports a wing, every player has it.

**Current implementation:** until JWT verification is added, Crafting reads the acting player from
the `X-Player-Id` header instead of the cookie (internal callers must send it too), and receives
events over HTTP at `POST /crafting/internal/events` instead of WebSocket connections to Player,
Exam and World.

### Endpoints

<details>
<summary><b>GET</b> <code>/crafting/recipes</code> — List recipes with availability</summary>

**Caller:** client · **Auth:** cookie · **Idempotent:** —

`available` is computed for `sub` from the player's level (`GET /players/{id}`), passed subjects
and unlocked wings (both tracked locally from consumed events).

**Responses**

```json
// 200
[
  { "recipeId": 1, "name": "Barricade Kit", "inputs": { "wood": 4, "metal": 2 },
    "output": { "itemId": "barricade_kit", "name": "Barricade Kit", "quantity": 1 },
    "requires": {}, "available": true },
  { "recipeId": 5, "name": "Exam Cheat Sheet", "inputs": { "paper": 3, "wood": 1 },
    "output": { "itemId": "cheat_sheet", "name": "Exam Cheat Sheet", "quantity": 2 },
    "requires": { "level": 3, "subject": "math" }, "available": false }
]
```

</details>

<details>
<summary><b>POST</b> <code>/crafting/crafts</code> — Craft a recipe</summary>

**Caller:** client · **Auth:** cookie · **Idempotent:** yes

Flow: check availability → Resource `reservations` → Player `inventory/items` → Resource `commit`
→ write the craft record. If the inventory call fails the reservation is released, no craft record
is written and `409 DELIVERY_FAILED` is returned; the client can retry with the same key.

**Request body**

```json
{ "recipeId": 1 }
```

**Responses**

| Code | When |
|---|---|
| `201` | Crafted and delivered |
| `403 RECIPE_LOCKED` | Requirements not met |
| `404 RECIPE_NOT_FOUND` | No such recipe |
| `409 INSUFFICIENT_RESOURCES` | Resource reservation refused |
| `409 DELIVERY_FAILED` | Player Service unavailable; nothing was spent |

```json
// 201
{ "craftId": "f4e2…", "recipeId": 1, "itemId": "barricade_kit", "quantity": 1, "status": "completed" }
```

</details>

<details>
<summary><b>GET</b> <code>/crafting/recipes/{id}</code> — One recipe</summary>

**Caller:** client, internal · **Auth:** cookie or `X-Internal-Key` · **Idempotent:** —

`available` is included when a player is known, computed as in the list.

**Responses**

| Code | When |
|---|---|
| `200` | Found; body is the `Recipe` |
| `404 RECIPE_NOT_FOUND` | No such recipe |

</details>

<details>
<summary><b>POST</b> <code>/crafting/recipes</code> — Create a recipe</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** —

**Request body**

```json
{ "name": "Barricade Kit", "inputs": { "wood": 4, "metal": 2 },
  "output": { "itemId": "barricade_kit", "name": "Barricade Kit", "quantity": 1 },
  "requires": { "level": 2 } }
```

| Field | Type | Rules |
|---|---|---|
| `name` | string | Required |
| `inputs` | map<string,int> | Non-empty, every amount ≥ 1 |
| `output` | `{ itemId, name, quantity }` | All required, `quantity` ≥ 1; `itemId` must exist in Player's catalogue |
| `requires` | `{ level?, subject?, wingId? }` | Optional; `level` ≥ 1 |

**Responses**

| Code | When |
|---|---|
| `201` | Created; body is the `Recipe` without `available` |

</details>

<details>
<summary><b>PUT</b> <code>/crafting/recipes/{id}</code> — Replace a recipe</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** yes (naturally)

Same body and rules as create.

**Responses**

| Code | When |
|---|---|
| `200` | Updated; body is the `Recipe` |
| `404 RECIPE_NOT_FOUND` | No such recipe |

</details>

<details>
<summary><b>DELETE</b> <code>/crafting/recipes/{id}</code> — Delete a recipe</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** —

Past craft records keep their `recipeId`.

**Responses**

| Code | When |
|---|---|
| `204` | Deleted |
| `404 RECIPE_NOT_FOUND` | No such recipe |

</details>

<details>
<summary><b>GET</b> <code>/crafting/crafts</code> — The player's craft history</summary>

**Caller:** client · **Auth:** cookie · **Idempotent:** —

Newest first.

**Responses**

```json
// 200
[ { "craftId": "f4e2…", "playerId": 42, "recipeId": 1, "itemId": "barricade_kit", "quantity": 1,
    "status": "completed", "createdAt": "2026-09-09T18:04:11Z" } ]
```

</details>

<details>
<summary><b>GET</b> <code>/crafting/crafts/{id}</code> — One of the player's crafts</summary>

**Caller:** client · **Auth:** cookie · **Idempotent:** —

**Responses**

| Code | When |
|---|---|
| `200` | Found; body is the `Craft` |
| `404 CRAFT_NOT_FOUND` | No such craft, or it belongs to another player |

</details>

<details>
<summary><b>POST</b> <code>/crafting/internal/events</code> — Receive a service event</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** yes (deduplicated on `eventId`)

Takes one event in the standard [envelope](#envelope). Stands in for the WebSocket consumers until
they are built; both apply events the same way.

**Responses**

```json
// 200 — status is processed, duplicate (eventId seen before) or ignored (type Crafting does not consume)
{ "eventId": "6f1c0c3e-…", "status": "processed" }
```

</details>

### Events

<details>
<summary><b>consumes</b> <code>player.leveled_up</code>, <code>exam.completed</code>, <code>world.wing_unlocked</code></summary>

Each updates the per-player unlock state used to compute `available`:
`player.leveled_up` → level, `exam.completed` (passed) → subjects, `world.wing_unlocked` → wings.

</details>

### Schemas

<details>
<summary>Recipe, Craft</summary>

```
Recipe { recipeId: int, name: string, inputs: map<string,int>,
         output: { itemId: string, name: string, quantity: int },
         requires: { level: int?, subject: string?, wingId: int? }, available: bool }
Craft  { craftId: uuid, playerId: int, recipeId: int, itemId: string, quantity: int,
         status: enum(completed), createdAt: datetime }
```

</details>

---

## Event summary

| Event | Payload | Producer | Consumers |
|---|---|---|---|
| `player.registered` | `{ playerId, username }` | Player | Base, Resource |
| `player.leveled_up` | `{ playerId, level }` | Player | Crafting |
| `game.action_completed` | `{ actionId, sessionId, playerId, type, roomId, nodeId?, completedAt }` | Game | Resource |
| `game.presence_changed` | `{ playerId, online }` | Game | Player |
| `resource.gathered` | `{ actionId, playerId, resourceType, amount, nodeId }` | Resource | Game |
| `exam.completed` | `{ examId, playerId, subject, passed, grade }` | Exam | World, Game, Crafting |
| `world.wing_unlocked` | `{ wingId, name, roomIds }` | World | Game, Crafting |
