# In Kahoots with the Undead

An educational zombie-survival game set on a university campus. Players explore the world, gather resources, improve their base, craft items, and survive encounters by completing exams.

## Documentation

- [Communication architecture](communication.md): protocols, authentication, service calls, and real-time events.
- [Technology choices](technologies.md): languages, frameworks, databases, and service responsibilities.
- [Architecture diagram](architecture.png): overview of the system architecture and service relationships.

## Planned service layout

```text
services/
|-- player_service/    # Player API and player-owned data
`-- game_service/      # Game sessions and game-related data
```

The Player Service and Game Service will be implemented under `services/`.

## Architecture at a glance

- The client uses WebSockets for live game-session updates.
- The client uses REST/JSON for authentication and direct domain actions.
- Services communicate over REST/JSON and keep their data in separate PostgreSQL databases.
- The Player Service issues JWTs. Internal service calls also require an internal service credential.
