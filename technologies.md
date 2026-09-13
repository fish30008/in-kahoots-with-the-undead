# Technologies & Stack Choices

These are proposed implementation choices for the planned services. They describe the target architecture, not completed code in the current workspace.

## 1. Language Split

To meet the multi-language requirement, the project is divided between two languages:

| Language | Framework & DB | Role | Services |
|---|---|---|---|
| **Go** | Gin + PostgreSQL | Transactional CRUD, data integrity | Player, Exam, World, Zombie, Base, Crafting |
| **TypeScript** | Node.js + Express (or NestJS) + PostgreSQL | Real-time events, WebSockets | Game, Resource |

---

## 2. Per-Service Technical Breakdown

| Service | Language | Stack | Communication | Justification |
|---|---|---|---|---|
| **Player** | **Go** | Gin, GORM, PostgreSQL | REST | Strong consistency and simple database transactions for atomic item trading. |
| **Game** | **TypeScript** | Express / Socket.IO, PostgreSQL | WebSockets + REST | A non-blocking event loop suits WebSocket connections and action timers. |
| **Exam** | **Go** | Gin, PostgreSQL | REST | Simple question retrieval and exam grading. |
| **World** | **Go** | Gin, PostgreSQL | REST | Relational queries for campus rooms and spawn locations. |
| **Zombie** | **Go** | Gin, PostgreSQL | REST | Static configuration store for zombie stats and types. |
| **Resource** | **TypeScript** | Express, PostgreSQL | REST | Validates gathering actions and tracks resource balances. |
| **Base** | **Go** | Gin, PostgreSQL | REST | Tracks room barricades and base upgrade levels. |
| **Crafting** | **Go** | Gin, PostgreSQL | REST | Recipe evaluation and crafting logic. |

---

## 3. Trade-offs

- **Go:** Fast, low memory usage, and great for atomic database operations (trading), but requires more boilerplate.
- **TypeScript:** Extremely fast to set up for WebSockets and async timers, but dynamic typing requires careful validation.

## 4. Implementation status

| Area | Current repository state |
|---|---|
| Documentation | Present: architecture and technology notes. |
| Player Service | Directory exists at `services/player_service/`; no source or configuration files are present yet. |
| Other services | Described as planned services; no implementation directories are present in the current workspace snapshot. |

The word “implemented” should only be added after a service has source code, configuration, and a documented way to run or test it.