-- Zombie Service schema + seed data.
-- Runs once on an empty database (mounted into /docker-entrypoint-initdb.d/),
-- and is safe to re-run: tables are created only if missing and the seed is
-- inserted only while `zombies` is empty.
--
-- Constraint names match what TypeORM generates, so `synchronize` sees no
-- difference. Ids 5/6/7 are the math/physics/programming professors and 9/10
-- are non-professors, matching Exam Service's built-in zombie stand-in.

CREATE TABLE IF NOT EXISTS zombies (
    id          SERIAL            NOT NULL,
    type        character varying NOT NULL,
    name        character varying NOT NULL,
    subject     character varying,
    "spriteUrl" character varying NOT NULL,
    stats       jsonb             NOT NULL,
    abilities   jsonb             NOT NULL,
    "createdAt" timestamp without time zone NOT NULL DEFAULT now(),
    "updatedAt" timestamp without time zone NOT NULL DEFAULT now(),
    CONSTRAINT "PK_44ee775885a0b4343f3269e1b82" PRIMARY KEY (id)
);

INSERT INTO zombies (id, type, name, subject, "spriteUrl", stats, abilities)
SELECT * FROM (VALUES
    (1,  'tourist',   'Selfie Stick Sam',   NULL,          '/sprites/tourist_sam.png',
         '{"health": 50, "speed": 3, "attack": 4, "perception": 4}'::jsonb,  '["steal_resources", "sprint"]'::jsonb),
    (2,  'janitor',   'Mop Master',         NULL,          '/sprites/janitor.png',
         '{"health": 90, "speed": 2, "attack": 6, "perception": 2}'::jsonb,  '["sprint"]'::jsonb),
    (3,  'dean',      'Dean of Discipline', NULL,          '/sprites/dean.png',
         '{"health": 200, "speed": 1, "attack": 12, "perception": 6}'::jsonb, '["steal_xp"]'::jsonb),
    (4,  'tourist',   'Map Reader',         NULL,          '/sprites/tourist_map.png',
         '{"health": 55, "speed": 2, "attack": 3, "perception": 6}'::jsonb,  '["steal_xp", "sprint"]'::jsonb),
    (5,  'professor', 'Prof. Grosu',        'math',        '/sprites/prof_grosu.png',
         '{"health": 120, "speed": 1, "attack": 8, "perception": 3}'::jsonb, '["administer_exam"]'::jsonb),
    (6,  'professor', 'Prof. Volta',        'physics',     '/sprites/prof_volta.png',
         '{"health": 110, "speed": 1, "attack": 9, "perception": 4}'::jsonb, '["administer_exam"]'::jsonb),
    (7,  'professor', 'Prof. Lovelace',     'programming', '/sprites/prof_lovelace.png',
         '{"health": 100, "speed": 2, "attack": 7, "perception": 5}'::jsonb, '["administer_exam"]'::jsonb),
    (8,  'janitor',   'Night Shift Nick',   NULL,          '/sprites/janitor_night.png',
         '{"health": 80, "speed": 2, "attack": 7, "perception": 3}'::jsonb,  '["sprint"]'::jsonb),
    (9,  'tourist',   'Lost Erasmus',       NULL,          '/sprites/tourist.png',
         '{"health": 60, "speed": 3, "attack": 5, "perception": 5}'::jsonb,  '["steal_xp", "steal_resources", "sprint"]'::jsonb),
    (10, 'dean',      'Vice Dean',          NULL,          '/sprites/vice_dean.png',
         '{"health": 160, "speed": 1, "attack": 10, "perception": 5}'::jsonb, '["steal_xp"]'::jsonb)
) AS seed (id, type, name, subject, "spriteUrl", stats, abilities)
WHERE NOT EXISTS (SELECT 1 FROM zombies);

-- Keep the sequence past the explicit seed ids.
SELECT setval('zombies_id_seq', GREATEST((SELECT MAX(id) FROM zombies), 1));
