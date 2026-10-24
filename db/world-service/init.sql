-- World Service schema + seed data.
-- Runs once on an empty database (mounted into /docker-entrypoint-initdb.d/).

CREATE TABLE wings (
    wing_id             SERIAL PRIMARY KEY,
    name                TEXT    NOT NULL UNIQUE,
    unlocked            BOOLEAN NOT NULL DEFAULT FALSE,
    unlocked_by_subject TEXT    NULL
);

CREATE TABLE rooms (
    room_id SERIAL PRIMARY KEY,
    name    TEXT NOT NULL,
    type    TEXT NOT NULL CHECK (type IN ('laboratory', 'library', 'canteen', 'classroom', 'corridor', 'fafcab')),
    wing_id INT  NOT NULL REFERENCES wings (wing_id) ON DELETE RESTRICT
);
CREATE INDEX rooms_wing_id_idx ON rooms (wing_id);

CREATE TABLE resource_nodes (
    node_id       SERIAL PRIMARY KEY,
    room_id       INT  NOT NULL UNIQUE REFERENCES rooms (room_id) ON DELETE CASCADE,
    resource_type TEXT NOT NULL
);

CREATE TABLE spawn_points (
    point_id     SERIAL PRIMARY KEY,
    room_id      INT    NOT NULL REFERENCES rooms (room_id) ON DELETE CASCADE,
    zombie_types TEXT[] NOT NULL
);
CREATE INDEX spawn_points_room_id_idx ON spawn_points (room_id);

-- Transactional outbox for events this service publishes (served on GET /events).
CREATE TABLE outbox_events (
    seq         BIGSERIAL   PRIMARY KEY,
    event_id    UUID        NOT NULL UNIQUE,
    type        TEXT        NOT NULL,
    version     INT         NOT NULL DEFAULT 1,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    payload     JSONB       NOT NULL
);

-- Consumer side: dedupe on eventId and remember the last acked seq per producer.
CREATE TABLE processed_events (
    event_id     UUID        PRIMARY KEY,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE consumer_offsets (
    source   TEXT   PRIMARY KEY,
    last_seq BIGINT NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------------------------
-- Seed
-- ---------------------------------------------------------------------------

INSERT INTO wings (wing_id, name, unlocked, unlocked_by_subject) VALUES
    (1, 'Main Building',     TRUE,  NULL),
    (2, 'Physics Wing',      FALSE, 'physics'),
    (3, 'Programming Wing',  FALSE, 'programming'),
    (4, 'Math Wing',         FALSE, 'math');

INSERT INTO rooms (room_id, name, type, wing_id) VALUES
    (1,  'FAF Cab',              'fafcab',     1),
    (2,  'Main Corridor',        'corridor',   1),
    (3,  'Lab 204',              'laboratory', 1),
    (4,  'Canteen',              'canteen',    1),
    (5,  'Central Library',      'library',    1),
    (6,  'Physics Lab',          'laboratory', 2),
    (7,  'Lecture Hall 1-01',    'classroom',  2),
    (8,  'Physics Corridor',     'corridor',   2),
    (9,  'Server Room',          'laboratory', 3),
    (10, 'Classroom 3-12',       'classroom',  3),
    (11, 'Programming Corridor', 'corridor',   3),
    (12, 'Math Library',         'library',    4),
    (13, 'Classroom 4-05',       'classroom',  4),
    (14, 'Math Corridor',        'corridor',   4);

INSERT INTO resource_nodes (node_id, room_id, resource_type) VALUES
    (1, 3,  'metal'),
    (2, 4,  'food'),
    (3, 5,  'wood'),
    (4, 6,  'metal'),
    (5, 9,  'metal'),
    (6, 12, 'wood');

INSERT INTO spawn_points (point_id, room_id, zombie_types) VALUES
    (1, 2,  ARRAY['tourist', 'janitor']),
    (2, 3,  ARRAY['professor', 'tourist']),
    (3, 7,  ARRAY['professor']),
    (4, 8,  ARRAY['tourist', 'janitor']),
    (5, 10, ARRAY['professor']),
    (6, 11, ARRAY['dean', 'tourist']),
    (7, 13, ARRAY['professor']),
    (8, 14, ARRAY['janitor']);

INSERT INTO consumer_offsets (source, last_seq) VALUES ('exam', 0);

-- Keep sequences past the explicit seed ids.
SELECT setval('wings_wing_id_seq',          (SELECT MAX(wing_id)  FROM wings));
SELECT setval('rooms_room_id_seq',          (SELECT MAX(room_id)  FROM rooms));
SELECT setval('resource_nodes_node_id_seq', (SELECT MAX(node_id)  FROM resource_nodes));
SELECT setval('spawn_points_point_id_seq',  (SELECT MAX(point_id) FROM spawn_points));
