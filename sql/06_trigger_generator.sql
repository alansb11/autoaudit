-- ============================================================================
-- AutoAudit · 06_trigger_generator.sql
-- Módulo de generación dinámica de triggers.
--
--   install_triggers(schema, tabla)   Lee audit_config y crea UN trigger AFTER por cada
--                                     evento habilitado; elimina los de eventos sin configuración.
--   uninstall_triggers(schema, tabla) Elimina todos los triggers de la tabla.
--   v_trigger_status                  Compara trigger_registry contra pg_trigger (estado real).
--
-- Ambas devuelven una fila por evento: trigger_name | event_type | status | detail
--   status = INSTALLED | REMOVED | SKIPPED | ERROR
-- Los errores se capturan por evento, se guardan en trigger_registry.last_error
-- y no interrumpen a los demás eventos.
-- Requiere que el dueño de estas funciones sea superusuario o dueño de la tabla origen.
-- ============================================================================

CREATE OR REPLACE FUNCTION autoaudit.install_triggers(p_schema TEXT, p_table TEXT)
RETURNS TABLE (trigger_name TEXT, event_type TEXT, status TEXT, detail TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, autoaudit, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_id_table BIGINT;
    r          RECORD;
    v_trg      TEXT;
    v_sql      TEXT;
    v_needed   BOOLEAN;
BEGIN
    PERFORM autoaudit.assert_admin();

    SELECT t.id_table INTO v_id_table
    FROM autoaudit.audited_table t
    WHERE t.schema_name = p_schema AND t.table_name = p_table AND t.is_active;

    IF v_id_table IS NULL THEN
        RAISE EXCEPTION 'AutoAudit: la tabla %.% no está registrada o no está activa', p_schema, p_table;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM autoaudit.v_db_tables v
                   WHERE v.schema_name = p_schema AND v.table_name = p_table) THEN
        RAISE EXCEPTION 'AutoAudit: la tabla %.% ya no existe en la base de datos', p_schema, p_table;
    END IF;

    FOR r IN SELECT e.id_event, e.event_code FROM autoaudit.audit_event e ORDER BY e.id_event LOOP
        v_trg := 'trg_audit_' || left(p_table, 45) || '_' || lower(left(r.event_code, 3));
        v_sql := NULL;

        SELECT EXISTS (
            SELECT 1
            FROM autoaudit.audit_config cfg
            JOIN autoaudit.audited_column ac ON ac.id_column = cfg.id_column
            WHERE ac.id_table = v_id_table AND ac.is_active
              AND cfg.is_enabled AND cfg.id_event = r.id_event
        ) INTO v_needed;

        BEGIN
            IF v_needed THEN
                EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I', v_trg, p_schema, p_table);
                v_sql := format(
                    'CREATE TRIGGER %I AFTER %s ON %I.%I FOR EACH ROW EXECUTE FUNCTION autoaudit.fn_audit_generic()',
                    v_trg, r.event_code, p_schema, p_table);
                EXECUTE v_sql;

                INSERT INTO autoaudit.trigger_registry
                    (id_table, trigger_name, event_type, function_name,
                     is_installed, installed_at, sql_definition, last_error)
                VALUES (v_id_table, v_trg, r.event_code, 'autoaudit.fn_audit_generic',
                        TRUE, now(), v_sql, NULL)
                ON CONFLICT (id_table, event_type) DO UPDATE
                    SET trigger_name   = EXCLUDED.trigger_name,
                        is_installed   = TRUE,
                        installed_at   = now(),
                        sql_definition = EXCLUDED.sql_definition,
                        last_error     = NULL;

                UPDATE autoaudit.audit_config cfg SET trigger_name = v_trg
                FROM autoaudit.audited_column ac
                WHERE ac.id_column = cfg.id_column
                  AND ac.id_table = v_id_table AND cfg.id_event = r.id_event;

                trigger_name := v_trg; event_type := r.event_code;
                status := 'INSTALLED'; detail := v_sql;
                RETURN NEXT;

            ELSIF EXISTS (SELECT 1 FROM autoaudit.trigger_registry tr
                          WHERE tr.id_table = v_id_table AND tr.event_type = r.event_code
                            AND tr.is_installed) THEN
                EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I', v_trg, p_schema, p_table);

                UPDATE autoaudit.trigger_registry tr
                SET is_installed = FALSE, last_error = NULL
                WHERE tr.id_table = v_id_table AND tr.event_type = r.event_code;

                UPDATE autoaudit.audit_config cfg SET trigger_name = NULL
                FROM autoaudit.audited_column ac
                WHERE ac.id_column = cfg.id_column
                  AND ac.id_table = v_id_table AND cfg.id_event = r.id_event;

                trigger_name := v_trg; event_type := r.event_code;
                status := 'REMOVED'; detail := 'sin configuración habilitada para este evento';
                RETURN NEXT;

            ELSE
                trigger_name := v_trg; event_type := r.event_code;
                status := 'SKIPPED'; detail := 'sin configuración habilitada para este evento';
                RETURN NEXT;
            END IF;

        EXCEPTION WHEN OTHERS THEN
            -- el subbloque ya revirtió el DDL fallido; se deja constancia del error
            INSERT INTO autoaudit.trigger_registry
                (id_table, trigger_name, event_type, function_name, is_installed, sql_definition, last_error)
            VALUES (v_id_table, v_trg, r.event_code, 'autoaudit.fn_audit_generic', FALSE, v_sql, SQLERRM)
            ON CONFLICT (id_table, event_type) DO UPDATE
                SET last_error = EXCLUDED.last_error;

            trigger_name := v_trg; event_type := r.event_code;
            status := 'ERROR'; detail := SQLERRM;
            RETURN NEXT;
        END;
    END LOOP;
END;
$$;


CREATE OR REPLACE FUNCTION autoaudit.uninstall_triggers(p_schema TEXT, p_table TEXT)
RETURNS TABLE (trigger_name TEXT, event_type TEXT, status TEXT, detail TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, autoaudit, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_id_table BIGINT;
    r          RECORD;
BEGIN
    PERFORM autoaudit.assert_admin();

    SELECT t.id_table INTO v_id_table
    FROM autoaudit.audited_table t
    WHERE t.schema_name = p_schema AND t.table_name = p_table;

    IF v_id_table IS NULL THEN
        RAISE EXCEPTION 'AutoAudit: la tabla %.% no está registrada', p_schema, p_table;
    END IF;

    FOR r IN SELECT tr.trigger_name AS tname, tr.event_type AS ev
             FROM autoaudit.trigger_registry tr
             WHERE tr.id_table = v_id_table AND tr.is_installed
    LOOP
        BEGIN
            EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I', r.tname, p_schema, p_table);

            UPDATE autoaudit.trigger_registry tr
            SET is_installed = FALSE, last_error = NULL
            WHERE tr.id_table = v_id_table AND tr.trigger_name = r.tname;

            trigger_name := r.tname; event_type := r.ev;
            status := 'REMOVED'; detail := 'trigger eliminado';
            RETURN NEXT;
        EXCEPTION WHEN OTHERS THEN
            UPDATE autoaudit.trigger_registry tr SET last_error = SQLERRM
            WHERE tr.id_table = v_id_table AND tr.trigger_name = r.tname;

            trigger_name := r.tname; event_type := r.ev;
            status := 'ERROR'; detail := SQLERRM;
            RETURN NEXT;
        END;
    END LOOP;

    UPDATE autoaudit.audit_config cfg SET trigger_name = NULL
    FROM autoaudit.audited_column ac
    WHERE ac.id_column = cfg.id_column AND ac.id_table = v_id_table;
END;
$$;


-- Estado real: ¿lo que dice trigger_registry coincide con pg_trigger?
CREATE OR REPLACE VIEW autoaudit.v_trigger_status AS
SELECT t.schema_name,
       t.table_name,
       r.event_type,
       r.trigger_name,
       r.is_installed                       AS registry_says_installed,
       (pg.oid IS NOT NULL)                 AS exists_in_postgres,
       (pg.oid IS NOT NULL) = r.is_installed AS in_sync,
       r.installed_at,
       r.last_error
FROM autoaudit.trigger_registry r
JOIN autoaudit.audited_table t ON t.id_table = r.id_table
LEFT JOIN pg_namespace n ON n.nspname = t.schema_name
LEFT JOIN pg_class c     ON c.relnamespace = n.oid AND c.relname = t.table_name
LEFT JOIN pg_trigger pg  ON pg.tgrelid = c.oid
                        AND pg.tgname = r.trigger_name
                        AND NOT pg.tgisinternal;
