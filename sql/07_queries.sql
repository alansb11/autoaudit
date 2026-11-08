-- ============================================================================
-- AutoAudit · 07_queries.sql
-- Consultas históricas PARAMETRIZADAS (funciones) + vista de detalle.
-- Todas devuelven las mismas columnas (v_audit_log_detail) y aceptan rango de fechas,
-- límite (NULL = sin límite) y orden (p_desc = TRUE: más reciente primero;
-- FALSE: orden cronológico ascendente).
--
-- Ejemplos:
--   SELECT * FROM autoaudit.history_by_user('juan');
--   SELECT * FROM autoaudit.history_by_user('juan', '2026-11-01', '2026-11-30', 500, FALSE);
--   SELECT * FROM autoaudit.history_by_column('public', 'clientes', 'saldo');
--   SELECT * FROM autoaudit.history_by_row('public', 'clientes', '{"id": 1}');
--
-- Exportar (desde psql):
--   \copy (SELECT * FROM autoaudit.history_by_column('public','clientes','saldo',NULL,NULL,NULL,FALSE)) TO 'saldo.csv' CSV HEADER
--   \copy (SELECT jsonb_pretty(jsonb_agg(h)) FROM autoaudit.history_by_user('juan') h) TO 'juan.json'
-- ============================================================================

CREATE OR REPLACE VIEW autoaudit.v_audit_log_detail AS
SELECT l.id_log,
       l.change_id,
       l.operation_ts,
       l.operation,
       u.db_username,
       s.hostname,
       l.client_ip,
       l.schema_name,
       l.table_name,
       l.column_name,
       l.pk_values,
       l.old_value,
       l.new_value,
       l.id_config,
       l.session_id
FROM autoaudit.audit_log l
LEFT JOIN autoaudit.audit_user    u ON u.id_user    = l.id_user
LEFT JOIN autoaudit.audit_station s ON s.id_station = l.id_station;


-- Cambios realizados por un usuario
CREATE OR REPLACE FUNCTION autoaudit.history_by_user(
    p_username TEXT,
    p_from     TIMESTAMPTZ DEFAULT NULL,
    p_to       TIMESTAMPTZ DEFAULT NULL,
    p_limit    INTEGER     DEFAULT 1000,
    p_desc     BOOLEAN     DEFAULT TRUE)
RETURNS SETOF autoaudit.v_audit_log_detail
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, autoaudit, pg_temp
AS $$
BEGIN
    IF p_desc THEN
        RETURN QUERY
        SELECT d.* FROM autoaudit.v_audit_log_detail d
        WHERE d.db_username = p_username
          AND (p_from IS NULL OR d.operation_ts >= p_from)
          AND (p_to   IS NULL OR d.operation_ts <  p_to)
        ORDER BY d.operation_ts DESC, d.id_log DESC
        LIMIT p_limit;
    ELSE
        RETURN QUERY
        SELECT d.* FROM autoaudit.v_audit_log_detail d
        WHERE d.db_username = p_username
          AND (p_from IS NULL OR d.operation_ts >= p_from)
          AND (p_to   IS NULL OR d.operation_ts <  p_to)
        ORDER BY d.operation_ts ASC, d.id_log ASC
        LIMIT p_limit;
    END IF;
END;
$$;


-- Cambios de una columna específica
CREATE OR REPLACE FUNCTION autoaudit.history_by_column(
    p_schema   TEXT,
    p_table    TEXT,
    p_column   TEXT,
    p_from     TIMESTAMPTZ DEFAULT NULL,
    p_to       TIMESTAMPTZ DEFAULT NULL,
    p_limit    INTEGER     DEFAULT 1000,
    p_desc     BOOLEAN     DEFAULT TRUE)
RETURNS SETOF autoaudit.v_audit_log_detail
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, autoaudit, pg_temp
AS $$
BEGIN
    IF p_desc THEN
        RETURN QUERY
        SELECT d.* FROM autoaudit.v_audit_log_detail d
        WHERE d.schema_name = p_schema AND d.table_name = p_table AND d.column_name = p_column
          AND (p_from IS NULL OR d.operation_ts >= p_from)
          AND (p_to   IS NULL OR d.operation_ts <  p_to)
        ORDER BY d.operation_ts DESC, d.id_log DESC
        LIMIT p_limit;
    ELSE
        RETURN QUERY
        SELECT d.* FROM autoaudit.v_audit_log_detail d
        WHERE d.schema_name = p_schema AND d.table_name = p_table AND d.column_name = p_column
          AND (p_from IS NULL OR d.operation_ts >= p_from)
          AND (p_to   IS NULL OR d.operation_ts <  p_to)
        ORDER BY d.operation_ts ASC, d.id_log ASC
        LIMIT p_limit;
    END IF;
END;
$$;


-- Historia de una fila concreta, identificada por su PK (ej. '{"id": 1}')
CREATE OR REPLACE FUNCTION autoaudit.history_by_row(
    p_schema   TEXT,
    p_table    TEXT,
    p_pk       JSONB,
    p_from     TIMESTAMPTZ DEFAULT NULL,
    p_to       TIMESTAMPTZ DEFAULT NULL,
    p_limit    INTEGER     DEFAULT 1000,
    p_desc     BOOLEAN     DEFAULT TRUE)
RETURNS SETOF autoaudit.v_audit_log_detail
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, autoaudit, pg_temp
AS $$
BEGIN
    IF p_desc THEN
        RETURN QUERY
        SELECT d.* FROM autoaudit.v_audit_log_detail d
        WHERE d.schema_name = p_schema AND d.table_name = p_table AND d.pk_values @> p_pk
          AND (p_from IS NULL OR d.operation_ts >= p_from)
          AND (p_to   IS NULL OR d.operation_ts <  p_to)
        ORDER BY d.operation_ts DESC, d.id_log DESC
        LIMIT p_limit;
    ELSE
        RETURN QUERY
        SELECT d.* FROM autoaudit.v_audit_log_detail d
        WHERE d.schema_name = p_schema AND d.table_name = p_table AND d.pk_values @> p_pk
          AND (p_from IS NULL OR d.operation_ts >= p_from)
          AND (p_to   IS NULL OR d.operation_ts <  p_to)
        ORDER BY d.operation_ts ASC, d.id_log ASC
        LIMIT p_limit;
    END IF;
END;
$$;
