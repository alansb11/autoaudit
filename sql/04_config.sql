-- ============================================================================
-- AutoAudit · 04_config.sql
-- Funciones de configuración. TODAS exigen ser administrador y VALIDAN contra
-- el catálogo de PostgreSQL que la tabla y las columnas existan antes de guardar.
--
--   register_table(schema, tabla)                       -> id_table
--   register_column(schema, tabla, columna)             -> id_column
--   set_audit_config(schema, tabla, columna, evento, habilitado) -> id_config
--   enable_audit(schema, tabla, columnas[], eventos[])  -> registra + configura + instala triggers
--   disable_audit(schema, tabla, columnas[], eventos[]) -> desactiva y reajusta triggers
-- ============================================================================

CREATE OR REPLACE FUNCTION autoaudit.register_table(p_schema TEXT, p_table TEXT)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, autoaudit, pg_temp
AS $$
DECLARE
    v_oid      OID;
    v_pk       TEXT[];
    v_id_table BIGINT;
BEGIN
    PERFORM autoaudit.assert_admin();

    SELECT table_oid INTO v_oid
    FROM autoaudit.v_db_tables
    WHERE schema_name = p_schema AND table_name = p_table;

    IF v_oid IS NULL THEN
        RAISE EXCEPTION 'AutoAudit: la tabla %.% no existe o no es auditable', p_schema, p_table
            USING ERRCODE = 'undefined_table';
    END IF;

    SELECT COALESCE(array_agg(a.attname::text ORDER BY k.ord), '{}')
    INTO v_pk
    FROM pg_index i
    CROSS JOIN LATERAL unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
    WHERE i.indrelid = v_oid AND i.indisprimary;

    IF cardinality(v_pk) = 0 THEN
        RAISE WARNING 'AutoAudit: %.% no tiene PRIMARY KEY; pk_values quedará vacío en la bitácora', p_schema, p_table;
    END IF;

    INSERT INTO autoaudit.audited_table (schema_name, table_name, pk_columns)
    VALUES (p_schema, p_table, v_pk)
    ON CONFLICT (schema_name, table_name) DO UPDATE
        SET is_active  = TRUE,
            pk_columns = EXCLUDED.pk_columns,
            updated_at = now()
    RETURNING id_table INTO v_id_table;

    RETURN v_id_table;
END;
$$;


CREATE OR REPLACE FUNCTION autoaudit.register_column(p_schema TEXT, p_table TEXT, p_column TEXT)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, autoaudit, pg_temp
AS $$
DECLARE
    v_id_table  BIGINT;
    v_type      TEXT;
    v_id_column BIGINT;
BEGIN
    PERFORM autoaudit.assert_admin();

    SELECT id_table INTO v_id_table
    FROM autoaudit.audited_table
    WHERE schema_name = p_schema AND table_name = p_table;

    IF v_id_table IS NULL THEN
        RAISE EXCEPTION 'AutoAudit: la tabla %.% no está registrada (use register_table primero)', p_schema, p_table;
    END IF;

    SELECT data_type INTO v_type
    FROM autoaudit.v_db_columns
    WHERE schema_name = p_schema AND table_name = p_table AND column_name = p_column;

    IF v_type IS NULL THEN
        RAISE EXCEPTION 'AutoAudit: la columna %.%.% no existe', p_schema, p_table, p_column
            USING ERRCODE = 'undefined_column';
    END IF;

    INSERT INTO autoaudit.audited_column (id_table, column_name, data_type)
    VALUES (v_id_table, p_column, v_type)
    ON CONFLICT (id_table, column_name) DO UPDATE
        SET data_type = EXCLUDED.data_type, is_active = TRUE
    RETURNING id_column INTO v_id_column;

    RETURN v_id_column;
END;
$$;


CREATE OR REPLACE FUNCTION autoaudit.set_audit_config(
    p_schema TEXT, p_table TEXT, p_column TEXT, p_event TEXT, p_enabled BOOLEAN DEFAULT TRUE)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, autoaudit, pg_temp
AS $$
DECLARE
    v_id_column BIGINT;
    v_id_event  SMALLINT;
    v_id_config BIGINT;
BEGIN
    PERFORM autoaudit.assert_admin();

    SELECT ac.id_column INTO v_id_column
    FROM autoaudit.audited_column ac
    JOIN autoaudit.audited_table t ON t.id_table = ac.id_table
    WHERE t.schema_name = p_schema AND t.table_name = p_table AND ac.column_name = p_column;

    IF v_id_column IS NULL THEN
        RAISE EXCEPTION 'AutoAudit: la columna %.%.% no está registrada (use register_column primero)',
            p_schema, p_table, p_column;
    END IF;

    SELECT id_event INTO v_id_event FROM autoaudit.audit_event WHERE event_code = upper(p_event);
    IF v_id_event IS NULL THEN
        RAISE EXCEPTION 'AutoAudit: evento inválido "%" (use INSERT, UPDATE o DELETE)', p_event;
    END IF;

    INSERT INTO autoaudit.audit_config (id_column, id_event, is_enabled, created_by)
    VALUES (v_id_column, v_id_event, p_enabled, session_user)
    ON CONFLICT (id_column, id_event) DO UPDATE SET is_enabled = EXCLUDED.is_enabled
    RETURNING id_config INTO v_id_config;

    RETURN v_id_config;
END;
$$;


-- Atajo: registra tabla y columnas, activa los eventos e instala los triggers.
-- p_columns NULL = todas las columnas de la tabla.
CREATE OR REPLACE FUNCTION autoaudit.enable_audit(
    p_schema  TEXT,
    p_table   TEXT,
    p_columns TEXT[] DEFAULT NULL,
    p_events  TEXT[] DEFAULT ARRAY['INSERT','UPDATE','DELETE'])
RETURNS TABLE (trigger_name TEXT, event_type TEXT, status TEXT, detail TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, autoaudit, pg_temp
AS $$
DECLARE
    v_cols TEXT[];
    v_col  TEXT;
    v_ev   TEXT;
BEGIN
    PERFORM autoaudit.assert_admin();

    IF p_events IS NULL OR cardinality(p_events) = 0 THEN
        RAISE EXCEPTION 'AutoAudit: debe indicar al menos un evento';
    END IF;

    PERFORM autoaudit.register_table(p_schema, p_table);

    IF p_columns IS NULL THEN
        SELECT array_agg(column_name::text ORDER BY ordinal_position) INTO v_cols
        FROM autoaudit.v_db_columns
        WHERE schema_name = p_schema AND table_name = p_table;
    ELSE
        v_cols := p_columns;
    END IF;

    FOREACH v_col IN ARRAY v_cols LOOP
        PERFORM autoaudit.register_column(p_schema, p_table, v_col);   -- valida existencia
        FOREACH v_ev IN ARRAY p_events LOOP
            PERFORM autoaudit.set_audit_config(p_schema, p_table, v_col, v_ev, TRUE);
        END LOOP;
    END LOOP;

    RETURN QUERY SELECT * FROM autoaudit.install_triggers(p_schema, p_table);
END;
$$;


-- Desactiva auditoría.
--   Sin columnas ni eventos  -> tabla completa (is_active = FALSE y se eliminan sus triggers).
--   Con columnas y/o eventos -> solo esas combinaciones; los triggers sin configuración se eliminan.
-- La bitácora existente nunca se borra.
CREATE OR REPLACE FUNCTION autoaudit.disable_audit(
    p_schema  TEXT,
    p_table   TEXT,
    p_columns TEXT[] DEFAULT NULL,
    p_events  TEXT[] DEFAULT NULL)
RETURNS TABLE (trigger_name TEXT, event_type TEXT, status TEXT, detail TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, autoaudit, pg_temp
AS $$
DECLARE
    v_id_table BIGINT;
BEGIN
    PERFORM autoaudit.assert_admin();

    SELECT id_table INTO v_id_table
    FROM autoaudit.audited_table
    WHERE schema_name = p_schema AND table_name = p_table;

    IF v_id_table IS NULL THEN
        RAISE EXCEPTION 'AutoAudit: la tabla %.% no está registrada', p_schema, p_table;
    END IF;

    IF p_columns IS NULL AND p_events IS NULL THEN
        UPDATE autoaudit.audited_table SET is_active = FALSE, updated_at = now()
        WHERE id_table = v_id_table;
        RETURN QUERY SELECT * FROM autoaudit.uninstall_triggers(p_schema, p_table);
        RETURN;
    END IF;

    UPDATE autoaudit.audit_config cfg
    SET is_enabled = FALSE
    FROM autoaudit.audited_column ac, autoaudit.audit_event ev
    WHERE ac.id_column = cfg.id_column
      AND ev.id_event  = cfg.id_event
      AND ac.id_table  = v_id_table
      AND (p_columns IS NULL OR ac.column_name = ANY (p_columns))
      AND (p_events  IS NULL OR ev.event_code  = ANY (SELECT upper(e) FROM unnest(p_events) e));

    UPDATE autoaudit.audited_table SET updated_at = now() WHERE id_table = v_id_table;

    RETURN QUERY SELECT * FROM autoaudit.install_triggers(p_schema, p_table);
END;
$$;
