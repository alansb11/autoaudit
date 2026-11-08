-- ============================================================================
-- AutoAudit · 05_trigger_function.sql
-- Función genérica que ejecutan TODOS los triggers de auditoría.
--
-- Comportamiento:
--   * Lee de audit_config SOLO las columnas activas para (tabla, evento).
--   * INSERT/DELETE: registra todas las columnas configuradas.
--     UPDATE: registra únicamente las columnas configuradas cuyo valor cambió
--     (si ninguna cambió, no escribe nada y casi no cuesta).
--   * Una fila de bitácora por columna, enlazadas con change_id y apuntando a su id_config.
--   * Usuario real = session_user. (Dentro de SECURITY DEFINER, current_user
--     sería el dueño de la función, no quien hizo el cambio.)
--   * pk_values contiene SOLO las columnas de la PK, no el resto de la fila.
--   * Política de errores: si no se puede escribir la bitácora, el error se propaga
--     y se revierte el cambio original (no hay modificaciones sin auditoría).
-- ============================================================================

-- Usuario de la sesión -> id_user (lo crea si no existe)
CREATE OR REPLACE FUNCTION autoaudit.resolve_user()
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, autoaudit, pg_temp
AS $$
DECLARE
    v_id BIGINT;
BEGIN
    SELECT id_user INTO v_id FROM autoaudit.audit_user WHERE db_username = session_user;
    IF v_id IS NULL THEN
        INSERT INTO autoaudit.audit_user (db_username) VALUES (session_user)
        ON CONFLICT (db_username) DO NOTHING
        RETURNING id_user INTO v_id;
        IF v_id IS NULL THEN   -- otra sesión lo creó al mismo tiempo
            SELECT id_user INTO v_id FROM autoaudit.audit_user WHERE db_username = session_user;
        END IF;
    END IF;
    RETURN v_id;
END;
$$;

-- Estación de la sesión -> id_station (la crea si no existe).
-- IP: inet_client_addr() (NULL si se conecta por socket Unix local).
-- Nombre de host y SO no los conoce el servidor: la aplicación cliente puede enviarlos con
--     SET autoaudit.hostname = 'PC-CONTABILIDAD-01';
--     SET autoaudit.os_info  = 'Windows 11';
CREATE OR REPLACE FUNCTION autoaudit.resolve_station()
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, autoaudit, pg_temp
AS $$
DECLARE
    v_ip   INET := inet_client_addr();
    v_host TEXT := NULLIF(current_setting('autoaudit.hostname', TRUE), '');
    v_os   TEXT := NULLIF(current_setting('autoaudit.os_info',  TRUE), '');
    v_id   BIGINT;
    v_seen TIMESTAMPTZ;
BEGIN
    SELECT id_station, last_seen INTO v_id, v_seen
    FROM autoaudit.audit_station
    WHERE hostname IS NOT DISTINCT FROM v_host
      AND ip_address IS NOT DISTINCT FROM v_ip;

    IF v_id IS NULL THEN
        INSERT INTO autoaudit.audit_station (hostname, ip_address, os_info, last_seen)
        VALUES (v_host, v_ip, v_os, now())
        ON CONFLICT (hostname, ip_address) DO UPDATE SET last_seen = now()
        RETURNING id_station INTO v_id;
    ELSIF v_seen IS NULL OR v_seen < now() - INTERVAL '1 minute' THEN
        -- se actualiza como máximo 1 vez por minuto para no generar contención
        UPDATE autoaudit.audit_station SET last_seen = now(), os_info = COALESCE(v_os, os_info)
        WHERE id_station = v_id;
    END IF;
    RETURN v_id;
END;
$$;


CREATE OR REPLACE FUNCTION autoaudit.fn_audit_generic()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, autoaudit, pg_temp
AS $$
DECLARE
    v_id_table BIGINT;
    v_pk_cols  TEXT[];
    v_old      JSONB;
    v_new      JSONB;
    v_pk       JSONB;
    v_cfg_ids  BIGINT[];
    v_cols     TEXT[];
    v_user     BIGINT;
    v_station  BIGINT;
    v_change   BIGINT;
    v_session  TEXT;
BEGIN
    SELECT t.id_table, t.pk_columns
    INTO v_id_table, v_pk_cols
    FROM autoaudit.audited_table t
    WHERE t.schema_name = TG_TABLE_SCHEMA
      AND t.table_name  = TG_TABLE_NAME
      AND t.is_active;

    IF v_id_table IS NULL THEN
        RETURN NULL;                       -- tabla no activa: nada que auditar
    END IF;

    IF TG_OP IN ('UPDATE', 'DELETE') THEN v_old := to_jsonb(OLD); END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN v_new := to_jsonb(NEW); END IF;

    -- Configuraciones activas para este evento (y, en UPDATE, solo columnas que cambiaron)
    SELECT array_agg(cfg.id_config  ORDER BY ac.column_name),
           array_agg(ac.column_name ORDER BY ac.column_name)
    INTO v_cfg_ids, v_cols
    FROM autoaudit.audit_config  cfg
    JOIN autoaudit.audited_column ac ON ac.id_column = cfg.id_column
    JOIN autoaudit.audit_event    ev ON ev.id_event  = cfg.id_event
    WHERE ac.id_table  = v_id_table
      AND ac.is_active
      AND cfg.is_enabled
      AND ev.event_code = TG_OP
      AND (TG_OP <> 'UPDATE'
           OR (v_old -> ac.column_name) IS DISTINCT FROM (v_new -> ac.column_name));

    IF v_cols IS NULL THEN
        RETURN NULL;                       -- nada auditable cambió
    END IF;

    -- PK de la fila (valores anteriores en UPDATE/DELETE, nuevos en INSERT)
    IF cardinality(v_pk_cols) > 0 THEN
        SELECT jsonb_object_agg(k, COALESCE(COALESCE(v_old, v_new) -> k, 'null'::jsonb))
        INTO v_pk
        FROM unnest(v_pk_cols) AS k;
    END IF;

    v_user    := autoaudit.resolve_user();
    v_station := autoaudit.resolve_station();
    v_change  := nextval('autoaudit.seq_change_id');
    v_session := pg_backend_pid()::text || '/' || pg_current_xact_id()::text;

    INSERT INTO autoaudit.audit_log (
        change_id, id_config, id_table, id_user, id_station, operation, operation_ts,
        schema_name, table_name, column_name, pk_values, old_value, new_value,
        client_ip, session_id)
    SELECT v_change, u.id_config, v_id_table, v_user, v_station, TG_OP, clock_timestamp(),
           TG_TABLE_SCHEMA, TG_TABLE_NAME, u.col, v_pk,
           v_old -> u.col,                 -- NULL en INSERT
           v_new -> u.col,                 -- NULL en DELETE
           inet_client_addr(), v_session
    FROM unnest(v_cfg_ids, v_cols) AS u(id_config, col);

    RETURN NULL;                           -- valor ignorado en triggers AFTER
END;
$$;

COMMENT ON FUNCTION autoaudit.fn_audit_generic() IS
    'Función genérica de auditoría (trigger AFTER ... FOR EACH ROW). Una fila de audit_log por columna auditada.';
