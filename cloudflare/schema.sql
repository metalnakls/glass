CREATE TABLE IF NOT EXISTS weekly_install_checks (
    week_start TEXT NOT NULL,
    app_version TEXT NOT NULL,
    os_version TEXT NOT NULL,
    request_count INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (week_start, app_version, os_version)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS installations (
    installation_id TEXT PRIMARY KEY,
    app_version TEXT NOT NULL,
    os_version TEXT NOT NULL,
    mac_model TEXT NOT NULL,
    first_seen TEXT NOT NULL,
    version_first_seen TEXT NOT NULL,
    last_reported TEXT NOT NULL
) WITHOUT ROWID;
