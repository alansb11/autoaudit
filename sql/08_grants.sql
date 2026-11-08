-- ============================================================================
-- AutoAudit · 08_grants.sql
-- Permisos. Principio: nadie escribe directo en las tablas de AutoAudit;
-- la configuración se hace SOLO mediante funciones (SECURITY DEFINER) que exigen
-- ser administrador, y la bitácora solo la escribe fn_audit_generic.
--
--   PUBLIC            : sin acceso al esquema (ni a la bitácora, que contiene IPs).
--   autoaudit_reader  : consulta bitácora y reportes.
--   autoaudit_admin   : hereda reader + ejecuta las funciones de configuración.
-- ============================================================================

REVOKE ALL ON SCHEMA autoaudit FROM PUBLIC;
REVOKE ALL ON ALL TABLES    IN SCHEMA autoaudit FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA autoaudit FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA autoaudit FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA autoaudit REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

GRANT USAGE ON SCHEMA autoaudit TO autoaudit_reader, autoaudit_admin;
GRANT autoaudit_reader TO autoaudit_admin;

-- Lectura (reader): bitácora, actores y reportes
GRANT SELECT ON autoaudit.audit_log, autoaudit.audit_user, autoaudit.audit_station,
                autoaudit.v_audit_log_detail
    TO autoaudit_reader;
GRANT EXECUTE ON FUNCTION
    autoaudit.history_by_user(TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INTEGER, BOOLEAN),
    autoaudit.history_by_column(TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INTEGER, BOOLEAN),
    autoaudit.history_by_row(TEXT, TEXT, JSONB, TIMESTAMPTZ, TIMESTAMPTZ, INTEGER, BOOLEAN)
    TO autoaudit_reader;

-- Lectura de configuración y catálogo (admin)
GRANT SELECT ON autoaudit.audit_event, autoaudit.audited_table, autoaudit.audited_column,
                autoaudit.audit_config, autoaudit.trigger_registry, autoaudit.db_catalog_cache,
                autoaudit.v_db_tables, autoaudit.v_db_columns, autoaudit.v_trigger_status
    TO autoaudit_admin;

-- Escritura de configuración: solo vía funciones
GRANT EXECUTE ON FUNCTION
    autoaudit.register_table(TEXT, TEXT),
    autoaudit.register_column(TEXT, TEXT, TEXT),
    autoaudit.set_audit_config(TEXT, TEXT, TEXT, TEXT, BOOLEAN),
    autoaudit.enable_audit(TEXT, TEXT, TEXT[], TEXT[]),
    autoaudit.disable_audit(TEXT, TEXT, TEXT[], TEXT[]),
    autoaudit.install_triggers(TEXT, TEXT),
    autoaudit.uninstall_triggers(TEXT, TEXT),
    autoaudit.refresh_catalog_cache(TEXT)
    TO autoaudit_admin;

-- Nota: fn_audit_generic, resolve_user, resolve_station y assert_admin no necesitan
-- EXECUTE para nadie: los triggers no verifican ese permiso al dispararse y las demás
-- las invocan funciones SECURITY DEFINER.
