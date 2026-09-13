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

---

## Diagram cross-reference

This section maps every edge drawn in the architecture diagram to the concrete interaction it
resolves to below, so the README and the diagram never drift apart.

| Diagram edge | Label | Resolves to |
|---|---|---|
| Game → Player | `INVENTORY AND HP` | `POST /players/{id}/hp` (combat damage) — see [Player Service](#player-service) |
| Game → Zombie | `Config` | `GET /zombies` (zombie definitions loaded into Redis on session start) |
| Exam → World | `Notify about exam passed` | Kafka `exam.completed`, consumed by World |
| Base → Player | `Update` | `POST /players/{id}/inventory/items` (Kiki reward delivery) |
| Base → World | `Update` | `GET /world/rooms/{id}` (barricade room-lock check) |
| Zombie → Game | `Random event` | WebSocket `zombie:encounter` (Game rolls encounters using Zombie stats) |
| Base → Resource | `Spend Resources` | Reserve → commit flow, see [Resource Service](#resource-service) |
| Crafting → Resource | `Spend Resources` | Reserve → commit flow, see [Resource Service](#resource-service) |
| Player → Resource | `Inventory` | `GET /resources/players/{id}` (server-side fan-out from `GET /players/{id}/inventory`) — see note below |

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

---

## Data ownership

Each service owns its own database instance. No shared tables, no cross-service joins, no reading
another service's DB. Data owned elsewhere is fetched over REST or received via events.

| Service | Store |
|---|---|
| Player, Exam, World, Zombie, Base, Crafting, Resource | PostgreSQL, one database per service |
| Game | Redis (live session and timer state), PostgreSQL (session history) |

Sync REST when the caller needs the answer to continue. Kafka when something happened that other
services react to. Every event is wrapped in the same envelope and consumers deduplicate on `eventId`:

```json
{
  "eventId": "6f1c0c3e-…",
  "type": "ExamCompleted",
  "version": 1,
  "occurredAt": "2026-09-09T18:04:11Z",
  "payload": { }
}
```

Topics are named `<service>.<event>`, e.g. `exam.completed`.

---

## Player Service

Identity, session, profile, friends, XP/levels, **HP**, inventory, trading.

> **Diagram note:** the `INVENTORY AND HP` edge from Game means Player Service is the source of
> truth for player health, not just XP — Game reports combat outcomes here, it doesn't compute
> "is the player dead" itself.

### Endpoints

<details>
<summary><b>POST</b> <code>/auth/register</code> — Create a player account</summary>

**Caller:** client · **Auth:** none · **Idempotent:** no

Creates the account with level 1, 0 XP, full HP (100) and an empty inventory, then publishes
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

**Responses**

| Code | When |
|---|---|
| `204` | Cookie cleared |

</details>

<details>
<summary><b>GET</b> <code>/auth/jwks</code> — Public keys for JWT verification</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** —

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

```json
// 200
{ "id": 42, "username": "razvan", "level": 7, "xp": 1420, "hp": 76, "online": true }
```

</details>

<details>
<summary><b>GET</b> <code>/players/{id}</code> — A player's public profile</summary>

**Caller:** client, internal · **Auth:** cookie or `X-Internal-Key` · **Idempotent:** —

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
{ "id": 42, "username": "razvan", "level": 7, "xp": 1420, "hp": 76, "online": true }
```

</details>

<details>
<summary><b>GET</b> <code>/players/{id}/friends</code> — Friends list</summary>

**Caller:** client · **Auth:** cookie, `{id}` must equal `sub` · **Idempotent:** —

```json
// 200
[ { "id": 17, "username": "ana", "online": false }, { "id": 23, "username": "vlad", "online": true } ]
```

</details>

<details>
<summary><b>POST</b> <code>/players/{id}/friends</code> — Add a friend</summary>

**Caller:** client · **Auth:** cookie, `{id}` must equal `sub` · **Idempotent:** no (409 on repeat)

Friendship is symmetric: one call creates both directions.

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

</details>

<details>
<summary><b>DELETE</b> <code>/players/{id}/friends/{friendId}</code> — Remove a friend</summary>

**Caller:** client · **Auth:** cookie, `{id}` must equal `sub` · **Idempotent:** yes (naturally)

**Responses**

| Code | When |
|---|---|
| `204` | Removed |
| `404 NOT_FRIENDS` | No such friendship |

</details>

<details>
<summary><b>POST</b> <code>/players/{id}/xp</code> — Grant or take XP</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** yes

Applies `delta` to XP, floors at 0, recomputes level, publishes `player.leveled_up` if the level
went up. Called by Game (action rewards, exam rewards, zombie XP steals).

**Request body**

```json
{ "delta": 50, "reason": "exam" }
```

| Field | Type | Rules |
|---|---|---|
| `delta` | int | ≠ 0 |
| `reason` | enum(`action`\|`exam`\|`zombie_steal`) | |

**Responses**

```json
// 200
{ "xp": 1470, "level": 7 }
```

</details>

<details>
<summary><b>POST</b> <code>/players/{id}/hp</code> — Apply damage or healing</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** yes

This is the endpoint behind the diagram's `Game → Player: INVENTORY AND HP` edge. Applies `delta`
(negative for a zombie hit, positive for a heal item/rest), clamps to `[0, maxHp]`. If HP hits 0,
Player Service marks the player `downed`, publishes `player.downed`, and Game is responsible for
respawning them (moving them back to FAF Cab and resetting `status` to `idle`) via the WebSocket
flow — **Player Service does not know about rooms or sessions.**

**Request body**

```json
{ "delta": -8, "reason": "zombie_attack", "encounterId": "a5c2…" }
```

| Field | Type | Rules |
|---|---|---|
| `delta` | int | ≠ 0 |
| `reason` | enum(`zombie_attack`\|`heal`) | |
| `encounterId` | uuid? | Set for `zombie_attack`, used for the ledger/audit trail |

**Responses**

| Code | When |
|---|---|
| `200` | Applied |
| `404 PLAYER_NOT_FOUND` | No such player |

```json
// 200
{ "hp": 68, "maxHp": 100, "downed": false }
```

> **Pitfall to flag in your README/PR:** if Game calls both `/xp` (steal) and `/hp` (damage) for the
> same `zombie:attack`, that's two internal writes for one game event with no shared transaction.
> Use the same `encounterId` on both calls so a partial failure is at least detectable/replayable,
> and make the client-visible `zombie:attack` payload wait for both to succeed (or degrade
> explicitly) rather than reporting success optimistically.

</details>

<details>
<summary><b>GET</b> <code>/players/{id}/inventory</code> — Inventory contents</summary>

**Caller:** client, internal · **Auth:** cookie (`{id}` = `sub`) or `X-Internal-Key` · **Idempotent:** —

This is the diagram's `Player → Resource: Inventory` edge: Player Service owns *items*
(equipment/consumables) but, when called by the client, also fans out to Resource Service's
`GET /resources/players/{id}` and merges the raw-material balances into the response so the client
gets one call instead of two. Internal callers get items only (`includeResources=false` implicitly).

| Query param | Type | Default |
|---|---|---|
| `includeResources` | bool | `true` for `client` caller, `false` for `internal` |

**Responses**

```json
// 200
{
  "items": [
    { "itemId": "coffee", "name": "Coffee", "type": "consumable", "quantity": 3 }
  ],
  "resources": { "wood": 12, "metal": 4, "paper": 7, "food": 20, "textbooks": 2, "chemicals": 0, "electronics": 0 }
}
```

> **Pitfall:** this makes Player Service's read path depend on Resource Service's availability.
> If Resource is down, return `items` with `resources: null` and a `resourcesUnavailable: true`
> flag rather than failing the whole request — inventory items are still valid data worth serving.

</details>

<details>
<summary><b>POST</b> <code>/players/{id}/inventory/items</code> — Add items to inventory</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** yes

Upserts: adds `quantity` to the existing stack or creates it. Called by Crafting (crafted output)
and Base (Kiki rewards — the diagram's `Base → Player: Update` edge). `itemId` must exist in
Player Service's item catalogue.

**Request body**

```json
{ "itemId": "improvised_weapon", "quantity": 1 }
```

**Responses**

| Code | When |
|---|---|
| `200` | Stack updated |
| `404 PLAYER_NOT_FOUND` | No such player |
| `422 UNKNOWN_ITEM` | `itemId` not in catalogue |

</details>

<details>
<summary><b>POST</b> <code>/trades</code> — Transfer items to another player</summary>

**Caller:** client · **Auth:** cookie · **Idempotent:** yes

The sender is `sub`. In a single DB transaction: lock both inventories, verify the sender holds at
least `quantity`, subtract, add to the receiver, write the trade record. Players in different
lobbies/sessions can trade.

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

</details>

### Events

<details>
<summary><b>publishes</b> <code>player.registered</code></summary>

Base creates the starting base; Resource creates zero balances.

```json
{ "playerId": 42, "username": "razvan" }
```

**Consumers:** Base, Resource

</details>

<details>
<summary><b>publishes</b> <code>player.leveled_up</code></summary>

```json
{ "playerId": 42, "level": 8 }
```

**Consumers:** Crafting

</details>

<details>
<summary><b>publishes</b> <code>player.downed</code> — HP hit 0</summary>

```json
{ "playerId": 42 }
```

**Consumers:** Game

</details>

<details>
<summary><b>consumes</b> <code>game.presence_changed</code></summary>

Sets `online`. Out-of-order delivery resolved by `occurredAt`.

</details>

### Schemas

```
Player        { id: int, username: string, level: int, xp: int, hp: int, maxHp: int, online: bool }
InventoryItem { itemId: string, name: string, type: enum(consumable|cosmetic|equipment), quantity: int }
```

---

## Game Service

Lobbies, sessions, the day/night cycle, timed actions, zombie encounters. Owns no persistent
player or world data — coordinates the others and pushes live state over WebSockets.

### Endpoints

<details>
<summary><b>POST</b> <code>/game/lobbies</code> — Create a lobby</summary>

**Caller:** client · **Auth:** cookie · **Idempotent:** no

Max 4 players.

```json
// 201
{ "lobbyId": "c1d4…", "hostId": 42, "players": [42], "status": "waiting" }
```

</details>

<details>
<summary><b>POST</b> <code>/game/lobbies/{id}/players</code> — Join a lobby</summary>

**Caller:** client · **Auth:** cookie · **Idempotent:** yes (naturally)

| Code | When |
|---|---|
| `200` | Joined (or already a member) |
| `404 LOBBY_NOT_FOUND` | No such lobby |
| `409 LOBBY_FULL` | Already 4 players |
| `409 LOBBY_STARTED` | Session already running |

</details>

<details>
<summary><b>DELETE</b> <code>/game/lobbies/{id}/players/me</code> — Leave a lobby</summary>

**Caller:** client · **Auth:** cookie · **Idempotent:** yes (naturally)

If the host leaves, the earliest remaining member becomes host. An empty lobby is deleted.

</details>

<details>
<summary><b>POST</b> <code>/game/lobbies/{id}/start</code> — Start a session</summary>

**Caller:** client · **Auth:** cookie, must be the host · **Idempotent:** no

On start, Game loads the map (`GET /world/rooms`, `GET /world/spawn-points`) and zombie
definitions (`GET /zombies` — the diagram's `Game → Zombie: Config` edge) into Redis, places every
player in FAF Cab, and begins the first **day** phase. Phases alternate on a fixed timer (day
10 min, night 5 min); every switch emits `cycle:changed`.

```json
// 201
{
  "sessionId": "7a90…", "phase": "day", "cycle": 1, "phaseEndsAt": "2026-09-09T18:14:11Z",
  "players": [ { "playerId": 42, "roomId": 1, "status": "idle" } ]
}
```

</details>

<details>
<summary><b>GET</b> <code>/game/sessions/{id}</code> — Session snapshot</summary>

**Caller:** client · **Auth:** cookie, must be a session member · **Idempotent:** —

Used on reconnect before subscribing to the WebSocket stream.

</details>

<details>
<summary><b>POST</b> <code>/game/sessions/{id}/actions</code> — Start a timed action</summary>

**Caller:** client · **Auth:** cookie, must be a session member · **Idempotent:** no

| Type | Duration | On completion |
|---|---|---|
| `chop_benches` | 600 s | Publishes `game.action_completed`; Resource awards wood |
| `scavenge` | 300 s | Publishes `game.action_completed`; Resource awards the room's node resource |
| `clear_room` | 180 s | Room is zombie-free for the rest of the cycle |
| `barricade_room` | 120 s | Game calls Base `POST /base/players/{id}/barricades` — `409` ends the action `interrupted` |
| `repair_base` | 240 s | Game calls Base `POST /base/players/{id}/upgrades { facility: "homeroom" }` — same rule |

```json
{ "type": "scavenge", "roomId": 3 }
```

| Code | When |
|---|---|
| `202` | Action started |
| `404 SESSION_NOT_FOUND` | No such session or not a member |
| `409 PLAYER_BUSY` | Player already has an action or is in an exam |
| `422 ROOM_LOCKED` | Room's wing is not unlocked |
| `422 INVALID_ACTION_FOR_ROOM` | e.g. `scavenge` in a room with no resource node |

</details>

<details>
<summary><b>GET</b> <code>/game/sessions/{id}/actions/{actionId}</code> — Action status</summary>

**Caller:** client · **Auth:** cookie, must be a session member · **Idempotent:** —

</details>

### WebSocket — namespace `/game`

Authenticated by the session cookie on handshake.

- **client → server** `session:join { sessionId }` / `session:leave`
- **server → client** `action:progress { actionId, progress }` — every 5 s
- **server → client** `action:completed` — gathering actions wait for `resource.gathered` first
- **server → client** `cycle:changed { sessionId, phase, cycle, phaseEndsAt }`
- **server → client** `zombie:encounter { encounterId, playerId, zombieId, zombieType }` — the
  diagram's `Zombie → Game: Random event` edge. Game rolls this using World spawn points +
  Zombie's `perception` stat; Zombie itself never calls Game or World.
- **server → client** `zombie:attack { encounterId, playerId, damage, stolenXp, stolenResources }`
  — Game has already called Player `POST /players/{id}/hp` (damage), Player
  `POST /players/{id}/xp` (steal) and Resource `POST /resources/players/{id}/steal`.
- **server → client** `exam:started { encounterId, examId }`
- **server → client** `world:wing_unlocked { wingId, name }`

### Events

<details>
<summary><b>publishes</b> <code>game.action_completed</code></summary>

```json
{ "actionId": "e3f1…", "sessionId": "7a90…", "playerId": 42, "type": "scavenge", "roomId": 3, "nodeId": 12, "completedAt": "2026-09-09T18:09:11Z" }
```

**Consumers:** Resource

</details>

<details>
<summary><b>publishes</b> <code>game.presence_changed</code></summary>

```json
{ "playerId": 42, "online": true }
```

**Consumers:** Player

</details>

<details>
<summary><b>consumes</b> <code>resource.gathered</code>, <code>exam.completed</code>, <code>world.wing_unlocked</code>, <code>player.downed</code></summary>

- `resource.gathered` → emits `action:completed` with the credited amount.
- `exam.completed` → ends the encounter, sets the player to `idle`, calls Player `POST /players/{id}/xp` with the reward if `passed`.
- `world.wing_unlocked` → marks rooms unlocked in Redis, emits `world:wing_unlocked`.
- `player.downed` → respawns the player at FAF Cab, sets `status: idle`.

</details>

### Schemas

```
ActionType { chop_benches | scavenge | clear_room | barricade_room | repair_base }
Lobby      { lobbyId: uuid, hostId: int, players: [int], status: enum(waiting|started) }
Session    { sessionId: uuid, phase: enum(day|night), cycle: int, phaseEndsAt: datetime,
             players: [{ playerId: int, roomId: int, status: enum(idle|busy|in_exam) }] }
Action     { actionId: uuid, playerId: int, type: ActionType, roomId: int,
             status: enum(in_progress|completed|interrupted), durationSeconds: int, completesAt: datetime }
```

---

## Exam Service

Exams, grading, per-player academic history and achievements.

<details>
<summary><b>POST</b> <code>/exams</code> — Create an exam for an encounter</summary>

**Caller:** internal (Game) · **Auth:** `X-Internal-Key` · **Idempotent:** yes

Picks the subject from the professor zombie (`GET /zombies/{zombieId}` → `subject`), draws 5
questions from the static bank, sets a 120 s deadline. `encounterId` makes a retried call return
the same exam.

```json
{ "playerId": 42, "zombieId": 5, "encounterId": "a5c2…" }
```

| Code | When |
|---|---|
| `201` | Exam created |
| `404 PLAYER_NOT_FOUND` | No such player |
| `422 NOT_A_PROFESSOR` | Zombie has no `subject` |

</details>

<details>
<summary><b>GET</b> <code>/exams/{id}</code> — Fetch an exam's questions</summary>

**Caller:** client · **Auth:** cookie, must be the exam's player · **Idempotent:** —

Correct answers are never included.

</details>

<details>
<summary><b>POST</b> <code>/exams/{id}/answers</code> — Submit answers</summary>

**Caller:** client · **Auth:** cookie, must be the exam's player · **Idempotent:** no (409 on repeat)

`grade = round(correct / total × 10)`, `passed = grade ≥ 5`. Checks achievements (e.g. all `math`
passed → `survived_the_pumpkin`), publishes `exam.completed`. Submission after `expiresAt` is
graded as failed (`grade = 1`).

| Code | When |
|---|---|
| `200` | Graded |
| `404 EXAM_NOT_FOUND` | No such exam or not yours |
| `409 ALREADY_SUBMITTED` | Already graded |

</details>

<details>
<summary><b>GET</b> <code>/exams/players/{id}</code> — Exam history</summary>

**Caller:** client · **Auth:** cookie, `{id}` must equal `sub` · **Idempotent:** —

</details>

<details>
<summary><b>GET</b> <code>/exams/players/{id}/achievements</code></summary>

**Caller:** client · **Auth:** cookie, `{id}` must equal `sub` · **Idempotent:** —

</details>

### Events

<details>
<summary><b>publishes</b> <code>exam.completed</code></summary>

This is the diagram's `Exam → World: Notify about exam passed` and `Exam → Game` edges, both
implemented as this one event rather than two direct calls, so a third consumer never needs a new
point-to-point integration.

```json
{ "examId": 17, "playerId": 42, "subject": "math", "passed": true, "grade": 8 }
```

**Consumers:** World (unlocks a wing if `passed`), Game (ends the encounter), Crafting (unlocks recipes)

</details>

### Schemas

```
Exam       { examId: int, playerId: int, subject: string, expiresAt: datetime,
             questions: [{ questionId: int, text: string, options: [string] }] }
ExamResult { examId: int, subject: string, passed: bool, grade: int, correct: int, total: int, takenAt: datetime }
```

---

## World Service

The campus: wings, rooms, resource nodes, zombie spawn points. Geography only — what players
*build* on it belongs to Base.

<details>
<summary><b>GET</b> <code>/world/rooms</code> — List rooms</summary>

**Caller:** client, internal · **Auth:** cookie or `X-Internal-Key` · **Idempotent:** —

Query params: `type`, `wingId`, `unlocked`.

</details>

<details>
<summary><b>GET</b> <code>/world/rooms/{id}</code> — One room</summary>

**Caller:** client, internal · **Auth:** cookie or `X-Internal-Key` · **Idempotent:** —

This is the diagram's `Base → World: Update` edge — despite the label, it's a read: Base calls
this to check `unlocked` before letting a barricade go up, it never writes to World.

| Code | When |
|---|---|
| `200` | Found |
| `404 ROOM_NOT_FOUND` | No such room |

</details>

<details>
<summary><b>GET</b> <code>/world/wings</code> — List wings</summary>

**Caller:** client, internal · **Auth:** cookie or `X-Internal-Key` · **Idempotent:** —

</details>

<details>
<summary><b>GET</b> <code>/world/spawn-points</code> — Zombie spawn points</summary>

**Caller:** internal (Game) · **Auth:** `X-Internal-Key` · **Idempotent:** —

Query param: `roomId?`.

</details>

### Events

<details>
<summary><b>consumes</b> <code>exam.completed</code> — Unlocks a wing on a pass</summary>

If `passed` and a wing has `unlockedBySubject == subject` and is still locked, it unlocks and
publishes `world.wing_unlocked`. Already-unlocked wings make it a no-op.

</details>

<details>
<summary><b>publishes</b> <code>world.wing_unlocked</code></summary>

```json
{ "wingId": 4, "name": "Math Wing", "roomIds": [14, 15, 16] }
```

**Consumers:** Game, Crafting

</details>

### Schemas

```
RoomType { laboratory | library | canteen | classroom | corridor | fafcab }
Room     { roomId: int, name: string, type: RoomType, wingId: int, unlocked: bool,
           resourceNode: { nodeId: int, resourceType: string }? }
Wing     { wingId: int, name: string, unlocked: bool, unlockedBySubject: string? }
```

---

## Zombie Service

Zombie definitions: types, stats, abilities, sprites. Read-only at runtime — it never initiates a
call to another service, which is why it has no outgoing edges in the diagram beyond the
informational one to World.

<details>
<summary><b>GET</b> <code>/zombies</code> — List zombie definitions</summary>

**Caller:** internal (Game) · **Auth:** `X-Internal-Key` · **Idempotent:** —

Query param: `type?`. This is the `Game → Zombie: Config` edge, called once per session start.

</details>

<details>
<summary><b>GET</b> <code>/zombies/{id}</code> — One zombie definition</summary>

**Caller:** client, internal · **Auth:** cookie or `X-Internal-Key` · **Idempotent:** —

| Code | When |
|---|---|
| `200` | Found |
| `404 ZOMBIE_NOT_FOUND` | No such zombie |

</details>

### Schemas

```
ZombieType { professor | tourist | dean | janitor }
Zombie     { zombieId: int, type: ZombieType, name: string, subject: string?, spriteUrl: string,
             stats: { health: int, speed: int, attack: int, perception: int },
             abilities: [enum(administer_exam|steal_xp|steal_resources|sprint)] }
```

`subject` is set only for `professor`.

---

## Resource Service

The resource economy: per-player balances, gathering, spending, a ledger of every change.

Spending is two-phase so a caller that fails after spending can undo it:
**reserve → do the work → commit** (or release). Reservations not committed within 60 s auto-release.

<details>
<summary><b>GET</b> <code>/resources/players/{id}</code> — Current balances</summary>

**Caller:** client, internal · **Auth:** cookie (`{id}` = `sub`) or `X-Internal-Key` · **Idempotent:** —

Balances exclude amounts held by open reservations. This is what Player Service calls for the
diagram's `Player → Resource: Inventory` edge.

</details>

<details>
<summary><b>GET</b> <code>/resources/players/{id}/ledger</code> — Change history</summary>

**Caller:** client · **Auth:** cookie, `{id}` must equal `sub` · **Idempotent:** —

Query params: `limit` (50, max 200), `before?`.

</details>

<details>
<summary><b>POST</b> <code>/resources/players/{id}/reservations</code> — Reserve resources</summary>

**Caller:** internal (Base, Crafting) · **Auth:** `X-Internal-Key` · **Idempotent:** yes

Atomically checks every requested resource and holds the amounts. Held amounts are invisible to
other reservations and to the balances endpoint. All-or-nothing.

```json
{ "resources": { "wood": 10, "metal": 5 } }
```

| Code | When |
|---|---|
| `201` | Reserved |
| `404 PLAYER_NOT_FOUND` | No balances for this player |
| `409 INSUFFICIENT_RESOURCES` | At least one resource short |

</details>

<details>
<summary><b>POST</b> <code>/resources/reservations/{id}/commit</code> — Finalize a spend</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** yes (naturally)

| Code | When |
|---|---|
| `200` | Committed (or already committed) |
| `404 RESERVATION_NOT_FOUND` | No such reservation |
| `410 RESERVATION_EXPIRED` | Auto-released after 60 s; reserve again |

</details>

<details>
<summary><b>DELETE</b> <code>/resources/reservations/{id}</code> — Release a reservation</summary>

**Caller:** internal · **Auth:** `X-Internal-Key` · **Idempotent:** yes (naturally)

| Code | When |
|---|---|
| `204` | Released (or already released/expired) |
| `404 RESERVATION_NOT_FOUND` | No such reservation |
| `409 ALREADY_COMMITTED` | Cannot release a committed reservation |

</details>

<details>
<summary><b>POST</b> <code>/resources/players/{id}/steal</code> — Tourist zombie theft</summary>

**Caller:** internal (Game) · **Auth:** `X-Internal-Key` · **Idempotent:** yes

Takes `min(requested, free balance)` per resource; never fails for insufficient balance.

```json
{ "resources": { "food": 5, "wood": 3 }, "encounterId": "a5c2…" }
```

</details>

### Events

<details>
<summary><b>consumes</b> <code>game.action_completed</code> — Credits gathered resources</summary>

Only for `chop_benches` (wood) and `scavenge` (the node's `resourceType`). Yield random 5–15.
Applied at most once per `actionId`. Publishes `resource.gathered` after crediting.

</details>

<details>
<summary><b>consumes</b> <code>player.registered</code> — Creates zero balances</summary>
</details>

<details>
<summary><b>publishes</b> <code>resource.gathered</code></summary>

```json
{ "actionId": "e3f1…", "playerId": 42, "resourceType": "food", "amount": 12, "nodeId": 12 }
```

**Consumers:** Game

</details>

### Schemas

```
LedgerEntry { entryId: uuid, kind: enum(gathered|spent|stolen), resourceType: string, amount: int,
              nodeId: int?, actionId: uuid?, reservationId: uuid?, at: datetime }
```

Resource types: `wood`, `metal`, `paper`, `food`, `textbooks`, `chemicals`, `electronics`.

---

## Base Service

What players have built: base level, facilities, barricades, storage, Kiki.

Every spend follows **reserve (Resource) → apply locally → commit (Resource)**; a failed local
write releases the reservation.

<details>
<summary><b>GET</b> <code>/base/players/{id}</code> — Base state</summary>

**Caller:** client · **Auth:** cookie, `{id}` must equal `sub` · **Idempotent:** —

| Code | When |
|---|---|
| `200` | Found |
| `404 BASE_NOT_FOUND` | Player never registered |

</details>

<details>
<summary><b>POST</b> <code>/base/players/{id}/upgrades</code> — Upgrade a facility</summary>

**Caller:** client, internal (Game, for `repair_base`) · **Auth:** cookie (`{id}` = `sub`) or `X-Internal-Key` · **Idempotent:** yes

Max level 5.

```json
{ "facility": "storage" }
```

| Code | When |
|---|---|
| `200` | Upgraded |
| `404 BASE_NOT_FOUND` | Player never registered |
| `409 INSUFFICIENT_RESOURCES` | Resource reservation refused |
| `422 MAX_LEVEL` | Already level 5 |

</details>

<details>
<summary><b>POST</b> <code>/base/players/{id}/barricades</code> — Build or reinforce a barricade</summary>

**Caller:** client, internal (Game, for `barricade_room`) · **Auth:** cookie (`{id}` = `sub`) or `X-Internal-Key` · **Idempotent:** yes

Checks the room with World (`GET /world/rooms/{roomId}`, must be `unlocked` — the diagram's
`Base → World: Update` edge), then reserve → increment → commit. Max level 3.

```json
{ "roomId": 2 }
```

| Code | When |
|---|---|
| `200` | Built / reinforced |
| `404 BASE_NOT_FOUND` | Player never registered |
| `409 INSUFFICIENT_RESOURCES` | Resource reservation refused |
| `422 ROOM_LOCKED` | Room's wing is locked |
| `422 MAX_LEVEL` | Already level 3 |

</details>

<details>
<summary><b>POST</b> <code>/base/players/{id}/kiki/feed</code> — Feed Kiki for a random reward</summary>

**Caller:** client · **Auth:** cookie, `{id}` must equal `sub` · **Idempotent:** yes

Spends food via Resource, rolls a reward (30%), delivers it via Player
`POST /players/{id}/inventory/items` (the diagram's `Base → Player: Update` edge). If delivery
fails, the reservation is released and `409 REWARD_DELIVERY_FAILED` is returned for retry.

```json
{ "resourceType": "food", "amount": 3 }
```

| Code | When |
|---|---|
| `200` | Fed; `reward` is null if nothing dropped |
| `409 INSUFFICIENT_RESOURCES` | Not enough food |
| `409 REWARD_DELIVERY_FAILED` | Player Service unavailable; nothing was spent |
| `422 KIKI_NOT_HUNGRY` | Fed within the last 10 minutes |

</details>

### Events

<details>
<summary><b>consumes</b> <code>player.registered</code> — Creates the starting base</summary>

FAF Cab (`roomId` 1) at level 1, storage 100, no barricades.

</details>

### Schemas

```
Facility { storage | kitchen | workshop | homeroom }
Base     { baseId: int, playerId: int, level: int, storageCapacity: int,
           facilities: [{ type: Facility, level: int }],
           barricades: [{ roomId: int, level: int }] }
```

---

## Crafting Service

Recipes and crafting. Output items are delivered into the Player Service inventory.

<details>
<summary><b>GET</b> <code>/crafting/recipes</code> — List recipes with availability</summary>

**Caller:** client · **Auth:** cookie · **Idempotent:** —

`available` is computed for `sub` from level (`GET /players/{id}`), passed subjects and unlocked
wings (tracked locally from consumed events).

</details>

<details>
<summary><b>POST</b> <code>/crafting/crafts</code> — Craft a recipe</summary>

**Caller:** client · **Auth:** cookie · **Idempotent:** yes

Flow: check availability → Resource `reservations` (`Crafting → Resource: Spend Resources`) →
Player `inventory/items` → Resource `commit`. If the inventory call fails, the reservation is
released, nothing is written, and `409 DELIVERY_FAILED` is returned for retry.

```json
{ "recipeId": 1 }
```

| Code | When |
|---|---|
| `201` | Crafted and delivered |
| `403 RECIPE_LOCKED` | Requirements not met |
| `404 RECIPE_NOT_FOUND` | No such recipe |
| `409 INSUFFICIENT_RESOURCES` | Resource reservation refused |
| `409 DELIVERY_FAILED` | Player Service unavailable; nothing was spent |

</details>

### Events

<details>
<summary><b>consumes</b> <code>player.leveled_up</code>, <code>exam.completed</code>, <code>world.wing_unlocked</code></summary>

Each updates the per-player unlock state used to compute `available`: `player.leveled_up` →
level, `exam.completed` (passed) → subjects, `world.wing_unlocked` → wings.

</details>

### Schemas

```
Recipe { recipeId: int, name: string, inputs: map<string,int>,
         output: { itemId: string, name: string, quantity: int },
         requires: { level: int?, subject: string?, wingId: int? }, available: bool }
```

---

## Event summary

| Topic | Payload | Producer | Consumers |
|---|---|---|---|
| `player.registered` | `{ playerId, username }` | Player | Base, Resource |
| `player.leveled_up` | `{ playerId, level }` | Player | Crafting |
| `player.downed` | `{ playerId }` | Player | Game |
| `game.action_completed` | `{ actionId, sessionId, playerId, type, roomId, nodeId?, completedAt }` | Game | Resource |
| `game.presence_changed` | `{ playerId, online }` | Game | Player |
| `resource.gathered` | `{ actionId, playerId, resourceType, amount, nodeId }` | Resource | Game |
| `exam.completed` | `{ examId, playerId, subject, passed, grade }` | Exam | World, Game, Crafting |
| `world.wing_unlocked` | `{ wingId, name, roomIds }` | World | Game, Crafting |