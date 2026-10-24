-- Exam Service schema + seed data.
-- Runs once on an empty database (mounted into /docker-entrypoint-initdb.d/).

-- Static question bank. correct_option is an index into options and is never sent to clients.
CREATE TABLE questions (
    question_id    SERIAL PRIMARY KEY,
    subject        TEXT   NOT NULL,
    text           TEXT   NOT NULL,
    options        TEXT[] NOT NULL CHECK (cardinality(options) >= 2),
    correct_option INT    NOT NULL CHECK (correct_option >= 0 AND correct_option < cardinality(options))
);
CREATE INDEX questions_subject_idx ON questions (subject);

CREATE TABLE exams (
    exam_id      SERIAL      PRIMARY KEY,
    player_id    INT         NOT NULL,
    zombie_id    INT         NOT NULL,
    encounter_id TEXT        NOT NULL UNIQUE,
    subject      TEXT        NOT NULL,
    expires_at   TIMESTAMPTZ NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    submitted_at TIMESTAMPTZ NULL
);
CREATE INDEX exams_player_id_idx ON exams (player_id);

-- Snapshot of the drawn questions, so editing or deleting a bank question never
-- changes an exam that is already in progress or graded.
CREATE TABLE exam_questions (
    exam_id        INT    NOT NULL REFERENCES exams (exam_id) ON DELETE CASCADE,
    position       INT    NOT NULL,
    question_id    INT    NOT NULL,
    text           TEXT   NOT NULL,
    options        TEXT[] NOT NULL,
    correct_option INT    NOT NULL,
    PRIMARY KEY (exam_id, position),
    UNIQUE (exam_id, question_id)
);

CREATE TABLE exam_results (
    exam_id   INT         PRIMARY KEY REFERENCES exams (exam_id) ON DELETE CASCADE,
    player_id INT         NOT NULL,
    subject   TEXT        NOT NULL,
    passed    BOOLEAN     NOT NULL,
    grade     INT         NOT NULL CHECK (grade BETWEEN 0 AND 10),
    correct   INT         NOT NULL,
    total     INT         NOT NULL,
    taken_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX exam_results_player_id_idx ON exam_results (player_id);

-- An achievement unlocks when the player has at least min_passed passed exams
-- (in `subject`, or any subject when NULL) and, if require_no_fails, no failed ones.
CREATE TABLE achievement_definitions (
    achievement_id   TEXT    PRIMARY KEY,
    name             TEXT    NOT NULL,
    subject          TEXT    NULL,
    min_passed       INT     NOT NULL DEFAULT 1,
    require_no_fails BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE player_achievements (
    player_id      INT         NOT NULL,
    achievement_id TEXT        NOT NULL REFERENCES achievement_definitions (achievement_id) ON DELETE CASCADE,
    unlocked_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (player_id, achievement_id)
);

-- Idempotency-Key replay store for POST /exams (keys kept 24h).
CREATE TABLE idempotency_keys (
    key        TEXT        PRIMARY KEY,
    status     INT         NOT NULL,
    response   JSONB       NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Transactional outbox for events this service publishes (served on GET /events).
CREATE TABLE outbox_events (
    seq         BIGSERIAL   PRIMARY KEY,
    event_id    UUID        NOT NULL UNIQUE,
    type        TEXT        NOT NULL,
    version     INT         NOT NULL DEFAULT 1,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    payload     JSONB       NOT NULL
);

-- ---------------------------------------------------------------------------
-- Seed
-- ---------------------------------------------------------------------------

INSERT INTO questions (subject, text, options, correct_option) VALUES
    ('math', 'd/dx of x^2 ?',                          ARRAY['x', '2x', 'x^2', '2'], 1),
    ('math', 'What is 7 * 8 ?',                         ARRAY['54', '56', '58', '64'], 1),
    ('math', 'Integral of 1/x dx ?',                    ARRAY['x', 'ln|x| + C', '1/x^2 + C', 'e^x + C'], 1),
    ('math', 'Determinant of [[1,2],[3,4]] ?',          ARRAY['-2', '2', '10', '-10'], 0),
    ('math', 'sin(pi / 2) = ?',                         ARRAY['0', '1', '-1', 'pi'], 1),
    ('math', 'Sum of interior angles of a triangle ?',  ARRAY['90', '180', '270', '360'], 1),
    ('math', 'log2(1024) = ?',                          ARRAY['8', '9', '10', '12'], 2),

    ('physics', 'Unit of force ?',                               ARRAY['Joule', 'Watt', 'Newton', 'Pascal'], 2),
    ('physics', 'Speed of light in vacuum (approx.) ?',          ARRAY['3e8 m/s', '3e6 m/s', '340 m/s', '1.5e8 m/s'], 0),
    ('physics', 'F = m * ?',                                     ARRAY['v', 'a', 'p', 't'], 1),
    ('physics', 'Ohm''s law ?',                                  ARRAY['V = IR', 'P = IV', 'E = mc^2', 'F = qE'], 0),
    ('physics', 'Unit of electrical resistance ?',               ARRAY['Ampere', 'Volt', 'Ohm', 'Tesla'], 2),
    ('physics', 'Acceleration due to gravity on Earth (approx.)?', ARRAY['1.6 m/s^2', '9.8 m/s^2', '12 m/s^2', '3.7 m/s^2'], 1),
    ('physics', 'Which particle has a negative charge ?',        ARRAY['Proton', 'Neutron', 'Electron', 'Photon'], 2),

    ('programming', 'Time complexity of binary search ?',        ARRAY['O(n)', 'O(log n)', 'O(n log n)', 'O(1)'], 1),
    ('programming', 'Which structure is LIFO ?',                 ARRAY['Queue', 'Stack', 'Heap', 'Tree'], 1),
    ('programming', 'HTTP status for "Not Found" ?',             ARRAY['400', '401', '404', '500'], 2),
    ('programming', 'Which keyword declares a constant in JS ?', ARRAY['var', 'let', 'const', 'static'], 2),
    ('programming', 'SQL clause to filter grouped rows ?',       ARRAY['WHERE', 'HAVING', 'ORDER BY', 'LIMIT'], 1),
    ('programming', 'Git command to create a commit ?',          ARRAY['git push', 'git add', 'git commit', 'git merge'], 2),
    ('programming', '0.1 + 0.2 === 0.3 in JavaScript ?',         ARRAY['true', 'false', 'undefined', 'throws'], 1);

INSERT INTO achievement_definitions (achievement_id, name, subject, min_passed, require_no_fails) VALUES
    ('first_steps',          'First Steps',          NULL,          1, FALSE),
    ('survived_the_pumpkin', 'Survived the Pumpkin', 'math',        1, TRUE),
    ('newtons_apple',        'Newton''s Apple',      'physics',     1, TRUE),
    ('hello_world',          'Hello, World',         'programming', 1, TRUE),
    ('honor_roll',           'Honor Roll',           NULL,          5, FALSE);
