-- Resource Service schema + seed data.
-- Runs once on an empty database (mounted into /docker-entrypoint-initdb.d/),
-- and is safe to re-run: tables and indexes are created only if missing and
-- each seed is inserted only while its table is empty.
--
-- Constraint and index names match what TypeORM generates, so `synchronize`
-- sees no difference. Players 1-3 get starting balances plus the ledger
-- history that explains them; node ids match World Service's seed
-- (node 1 = metal in Lab 204, node 2 = food in the Canteen).

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS balances (
    id             uuid              NOT NULL DEFAULT uuid_generate_v4(),
    "playerId"     integer           NOT NULL,
    "resourceType" character varying NOT NULL,
    amount         integer           NOT NULL DEFAULT 0,
    "createdAt"    timestamp without time zone NOT NULL DEFAULT now(),
    "updatedAt"    timestamp without time zone NOT NULL DEFAULT now(),
    CONSTRAINT "PK_74904758e813e401abc3d4261c2" PRIMARY KEY (id)
);
CREATE UNIQUE INDEX IF NOT EXISTS "IDX_a41b63d154879fcfaa89c1ddc8"
    ON balances ("playerId", "resourceType");

CREATE TABLE IF NOT EXISTS ledger_entries (
    id              uuid              NOT NULL DEFAULT uuid_generate_v4(),
    "playerId"      integer           NOT NULL,
    kind            character varying NOT NULL,
    "resourceType"  character varying NOT NULL,
    amount          integer           NOT NULL,
    "nodeId"        integer,
    "actionId"      uuid,
    "reservationId" uuid,
    "encounterId"   character varying,
    "createdAt"     timestamp without time zone NOT NULL DEFAULT now(),
    CONSTRAINT "PK_6efcb84411d3f08b08450ae75d5" PRIMARY KEY (id)
);
CREATE INDEX IF NOT EXISTS "IDX_b93018804caeaf1b1f2e7af35b" ON ledger_entries ("playerId");
CREATE INDEX IF NOT EXISTS "IDX_c55f97a86ba2c963da43015ce7" ON ledger_entries ("actionId");

CREATE TABLE IF NOT EXISTS reservations (
    id          uuid              NOT NULL DEFAULT uuid_generate_v4(),
    "playerId"  integer           NOT NULL,
    resources   jsonb             NOT NULL,
    status      character varying NOT NULL DEFAULT 'open',
    "expiresAt" timestamp with time zone NOT NULL,
    "createdAt" timestamp without time zone NOT NULL DEFAULT now(),
    "updatedAt" timestamp without time zone NOT NULL DEFAULT now(),
    CONSTRAINT "PK_da95cef71b617ac35dc5bcda243" PRIMARY KEY (id)
);
CREATE INDEX IF NOT EXISTS "IDX_2f8e3e7dedc43bee350102ab3d" ON reservations ("playerId");

-- Transactional outbox for events this service publishes (served on GET /events).
CREATE TABLE IF NOT EXISTS outbox_events (
    seq          BIGSERIAL         NOT NULL,
    "eventId"    uuid              NOT NULL,
    type         character varying NOT NULL,
    version      integer           NOT NULL,
    "occurredAt" timestamp with time zone NOT NULL,
    payload      jsonb             NOT NULL,
    CONSTRAINT "PK_cc48a1566b3b842a82f0b2615c8" PRIMARY KEY (seq),
    CONSTRAINT "UQ_2e11b9ee3518231eeea21f93c44" UNIQUE ("eventId")
);
CREATE INDEX IF NOT EXISTS "IDX_0b7668aa1aed034a544a7ad043" ON outbox_events (type);
CREATE INDEX IF NOT EXISTS "IDX_32e66e61ae685fb8829d619e29" ON outbox_events ("occurredAt");

-- Last acked seq per producer we consume from, and consumed eventIds.
CREATE TABLE IF NOT EXISTS consumer_offsets (
    producer    character varying NOT NULL,
    "lastSeq"   bigint            NOT NULL DEFAULT '0',
    "updatedAt" timestamp without time zone NOT NULL DEFAULT now(),
    CONSTRAINT "PK_744b03bc2ca34c02750f2841141" PRIMARY KEY (producer)
);

CREATE TABLE IF NOT EXISTS processed_events (
    "eventId"     uuid              NOT NULL,
    type          character varying NOT NULL,
    "processedAt" timestamp without time zone NOT NULL DEFAULT now(),
    CONSTRAINT "PK_6df2a6135cc301de873d3b3948c" PRIMARY KEY ("eventId")
);

-- ---------------------------------------------------------------------------
-- Seed data
-- ---------------------------------------------------------------------------

INSERT INTO balances ("playerId", "resourceType", amount)
SELECT * FROM (VALUES
    (1, 'wood', 12), (1, 'metal', 4), (1, 'paper', 7), (1, 'food', 20),
    (1, 'textbooks', 2), (1, 'chemicals', 0), (1, 'electronics', 0),
    (2, 'wood', 30), (2, 'metal', 10), (2, 'paper', 0), (2, 'food', 5),
    (2, 'textbooks', 0), (2, 'chemicals', 3), (2, 'electronics', 1),
    (3, 'wood', 0), (3, 'metal', 0), (3, 'paper', 0), (3, 'food', 0),
    (3, 'textbooks', 0), (3, 'chemicals', 0), (3, 'electronics', 0)
) AS seed ("playerId", "resourceType", amount)
WHERE NOT EXISTS (SELECT 1 FROM balances);

INSERT INTO ledger_entries ("playerId", kind, "resourceType", amount, "nodeId", "actionId", "encounterId", "createdAt")
SELECT "playerId", kind, "resourceType", amount, "nodeId", "actionId"::uuid, "encounterId", now() - age::interval
FROM (VALUES
    (1, 'gathered', 'wood',  22, NULL, '6d1e7a2c-0000-4000-8000-000000000001', NULL,        '3 hours'),
    (1, 'gathered', 'metal',  4, 1,    '6d1e7a2c-0000-4000-8000-000000000002', NULL,        '2 hours'),
    (1, 'gathered', 'food',  24, 2,    '6d1e7a2c-0000-4000-8000-000000000003', NULL,        '90 minutes'),
    (1, 'spent',    'wood', -10, NULL, NULL,                                   NULL,        '1 hour'),
    (1, 'gathered', 'paper',      7, NULL, '6d1e7a2c-0000-4000-8000-000000000006', NULL,   '80 minutes'),
    (1, 'gathered', 'textbooks',  2, NULL, '6d1e7a2c-0000-4000-8000-000000000007', NULL,   '70 minutes'),
    (1, 'stolen',   'food',  -4, NULL, NULL,                                   'enc-seed-1', '30 minutes'),
    (2, 'gathered', 'wood',  30, NULL, '6d1e7a2c-0000-4000-8000-000000000004', NULL,        '2 hours'),
    (2, 'gathered', 'metal', 10, 1,    '6d1e7a2c-0000-4000-8000-000000000005', NULL,        '1 hour'),
    (2, 'gathered', 'food',   5, 2,    '6d1e7a2c-0000-4000-8000-000000000008', NULL,        '50 minutes'),
    (2, 'gathered', 'chemicals',   3, NULL, '6d1e7a2c-0000-4000-8000-000000000009', NULL,   '40 minutes'),
    (2, 'gathered', 'electronics', 1, NULL, '6d1e7a2c-0000-4000-8000-00000000000a', NULL,   '20 minutes')
) AS seed ("playerId", kind, "resourceType", amount, "nodeId", "actionId", "encounterId", age)
WHERE NOT EXISTS (SELECT 1 FROM ledger_entries);
