CREATE TABLE IF NOT EXISTS dq.check_results (
    run_ts        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    layer         TEXT NOT NULL,           -- 'raw' | 'stg' | 'dwh'
    table_name    TEXT NOT NULL,
    check_name    TEXT NOT NULL,
    row_count     INT NOT NULL,
    status        TEXT NOT NULL            -- 'OK' | 'WARN' | 'FAIL'
);