import Foundation

/// Versioned schema migrations. Append new migrations; never edit a shipped one.
public enum Schema {
    public static let migrations: [(version: Int, sql: String)] = [
        (1, v1),
    ]

    public static func migrate(_ db: SQLiteDatabase) throws {
        try db.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL)")
        let applied = Set(try db.query("SELECT version FROM schema_migrations").compactMap { $0.int("version") })
        for migration in migrations where !applied.contains(migration.version) {
            try db.transaction {
                try db.execute(migration.sql)
                try db.run("INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)", migration.version, Date())
            }
        }
    }

    public static var currentVersion: Int { migrations.map(\.version).max() ?? 0 }

    static let v1 = """
    CREATE TABLE person (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        given_name TEXT,
        surname TEXT,
        sex TEXT NOT NULL DEFAULT 'U',
        birth_date TEXT, birth_raw TEXT, birth_qualifier TEXT, birth_year INTEGER, birth_place TEXT,
        death_date TEXT, death_raw TEXT, death_qualifier TEXT, death_year INTEGER, death_place TEXT,
        occupation TEXT,
        biography TEXT,
        country TEXT,
        image_url TEXT,
        image_license TEXT,
        is_private INTEGER NOT NULL DEFAULT 0,
        exclude_from_research INTEGER NOT NULL DEFAULT 0,
        is_living INTEGER,
        is_sample INTEGER NOT NULL DEFAULT 0,
        origin TEXT NOT NULL,
        private_blob BLOB,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE INDEX idx_person_name ON person(display_name COLLATE NOCASE);
    CREATE INDEX idx_person_surname ON person(surname COLLATE NOCASE);
    CREATE INDEX idx_person_birth_year ON person(birth_year);

    CREATE TABLE person_category (
        person_id TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
        category TEXT NOT NULL,
        PRIMARY KEY (person_id, category)
    ) WITHOUT ROWID;
    CREATE INDEX idx_person_category_cat ON person_category(category);

    CREATE TABLE person_alias (
        person_id TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
        alias TEXT NOT NULL,
        PRIMARY KEY (person_id, alias)
    ) WITHOUT ROWID;
    CREATE INDEX idx_person_alias ON person_alias(alias COLLATE NOCASE);

    CREATE TABLE identity (
        id TEXT PRIMARY KEY,
        person_id TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
        scheme TEXT NOT NULL,
        value TEXT NOT NULL,
        url TEXT,
        UNIQUE (scheme, value)
    );
    CREATE INDEX idx_identity_person ON identity(person_id);

    CREATE TABLE platform_account (
        id TEXT PRIMARY KEY,
        person_id TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
        platform TEXT NOT NULL,
        handle TEXT,
        external_id TEXT,
        url TEXT,
        title TEXT,
        subscriber_count INTEGER,
        UNIQUE (platform, external_id)
    );
    CREATE INDEX idx_platform_person ON platform_account(person_id);

    CREATE TABLE organization (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        kind TEXT NOT NULL,
        wikidata_qid TEXT UNIQUE
    );

    CREATE TABLE community (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        kind TEXT NOT NULL,
        summary TEXT,
        wikidata_qid TEXT UNIQUE
    );
    CREATE TABLE community_member (
        community_id TEXT NOT NULL REFERENCES community(id) ON DELETE CASCADE,
        person_id TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
        role TEXT,
        source_id TEXT REFERENCES source(id) ON DELETE SET NULL,
        PRIMARY KEY (community_id, person_id)
    ) WITHOUT ROWID;
    CREATE INDEX idx_community_member_person ON community_member(person_id);

    CREATE TABLE media_project (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        kind TEXT NOT NULL,
        year INTEGER,
        wikidata_qid TEXT UNIQUE,
        url TEXT
    );
    CREATE TABLE media_credit (
        project_id TEXT NOT NULL REFERENCES media_project(id) ON DELETE CASCADE,
        person_id TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
        role TEXT NOT NULL,
        PRIMARY KEY (project_id, person_id, role)
    ) WITHOUT ROWID;
    CREATE INDEX idx_media_credit_person ON media_credit(person_id);

    CREATE TABLE source (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        title TEXT NOT NULL,
        url TEXT,
        document_ref TEXT,
        publisher TEXT,
        license TEXT,
        reliability REAL NOT NULL,
        retrieved_at REAL NOT NULL
    );
    CREATE UNIQUE INDEX idx_source_url ON source(url) WHERE url IS NOT NULL;

    -- Graph edges. Undirected edges are stored once with from_id < to_id for dedup;
    -- traversal indexes cover both columns.
    CREATE TABLE relationship (
        id TEXT PRIMARY KEY,
        from_id TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
        to_id TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
        type TEXT NOT NULL,
        category TEXT NOT NULL,
        directed INTEGER NOT NULL,
        is_inferred INTEGER NOT NULL DEFAULT 0,
        verification TEXT NOT NULL,
        confidence REAL NOT NULL,
        start_date TEXT, start_year INTEGER,
        end_date TEXT, end_year INTEGER,
        last_checked REAL NOT NULL,
        provenance TEXT NOT NULL,
        context_project_id TEXT REFERENCES media_project(id) ON DELETE SET NULL,
        context_label TEXT,
        context_key TEXT NOT NULL DEFAULT '',
        created_at REAL NOT NULL,
        CHECK (from_id <> to_id),
        UNIQUE (from_id, to_id, type, context_key)
    );
    CREATE INDEX idx_rel_from ON relationship(from_id, type);
    CREATE INDEX idx_rel_to ON relationship(to_id, type);
    CREATE INDEX idx_rel_category ON relationship(category);
    CREATE INDEX idx_rel_verification ON relationship(verification);

    CREATE TABLE relationship_evidence (
        id TEXT PRIMARY KEY,
        relationship_id TEXT NOT NULL REFERENCES relationship(id) ON DELETE CASCADE,
        source_id TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
        description TEXT NOT NULL,
        quote TEXT,
        extracted_by TEXT NOT NULL,
        created_at REAL NOT NULL
    );
    CREATE INDEX idx_evidence_rel ON relationship_evidence(relationship_id);
    CREATE INDEX idx_evidence_source ON relationship_evidence(source_id);

    CREATE TABLE family_event (
        id TEXT PRIMARY KEY,
        person_id TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
        type TEXT NOT NULL,
        date TEXT, date_raw TEXT, year INTEGER,
        place TEXT,
        source_id TEXT REFERENCES source(id) ON DELETE SET NULL,
        details TEXT,
        related_person_id TEXT REFERENCES person(id) ON DELETE SET NULL
    );
    CREATE INDEX idx_family_event_person ON family_event(person_id);

    CREATE TABLE research_job (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        target TEXT NOT NULL,
        person_id TEXT REFERENCES person(id) ON DELETE SET NULL,
        status TEXT NOT NULL,
        priority INTEGER NOT NULL DEFAULT 0,
        progress REAL NOT NULL DEFAULT 0,
        cursor TEXT,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        created_at REAL NOT NULL,
        scheduled_for REAL NOT NULL,
        started_at REAL,
        finished_at REAL,
        refresh_interval REAL,
        dedup_key TEXT NOT NULL
    );
    CREATE INDEX idx_job_status ON research_job(status, scheduled_for, priority);
    CREATE INDEX idx_job_dedup ON research_job(dedup_key);

    CREATE TABLE research_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        job_id TEXT NOT NULL REFERENCES research_job(id) ON DELETE CASCADE,
        at REAL NOT NULL,
        level TEXT NOT NULL,
        message TEXT NOT NULL
    );
    CREATE INDEX idx_log_job ON research_log(job_id);

    -- HTTP response cache for research connectors (offline mode + rate-limit friendliness).
    CREATE TABLE source_cache (
        key TEXT PRIMARY KEY,
        body BLOB NOT NULL,
        fetched_at REAL NOT NULL,
        expires_at REAL NOT NULL
    );

    CREATE TABLE graph_snapshot (
        id TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        created_at REAL NOT NULL,
        node_count INTEGER NOT NULL,
        edge_count INTEGER NOT NULL
    );

    -- Persisted 3D layout so the universe opens instantly.
    CREATE TABLE node_layout (
        person_id TEXT PRIMARY KEY REFERENCES person(id) ON DELETE CASCADE,
        x REAL NOT NULL, y REAL NOT NULL, z REAL NOT NULL,
        cluster INTEGER NOT NULL DEFAULT 0
    ) WITHOUT ROWID;

    CREATE TABLE merge_proposal (
        id TEXT PRIMARY KEY,
        person_a TEXT NOT NULL,   -- no FK: proposals are kept as an audit trail after merges
        person_b TEXT NOT NULL,
        score REAL NOT NULL,
        reasons TEXT NOT NULL,
        conflicts TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at REAL NOT NULL,
        decided_at REAL,
        UNIQUE (person_a, person_b)
    );

    -- Original records preserved when two people are merged.
    CREATE TABLE merge_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        survivor_id TEXT NOT NULL,
        merged_id TEXT NOT NULL,
        snapshot TEXT NOT NULL,
        merged_at REAL NOT NULL
    );

    CREATE TABLE user_preference (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    """
}
