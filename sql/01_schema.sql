-- ============================================================================
-- AutoAudit · 01_schema.sql
-- Estructura de tablas, índices y protección de la bitácora.
-- Requiere PostgreSQL 15+ (usa UNIQUE NULLS NOT DISTINCT). Probado en 16.
-- Es idempotente: se puede ejecutar más de una vez.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS autoaudit;
COMMENT ON SCHEMA autoaudit IS 'Sistema de auditoría automatizado AutoAudit';

-- ---------------------------------------------------------------------------
-- Catálogo de eventos
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS autoaudit.audit_event (
    id_event    SMALLINT PRIMARY KEY,
    event_code  VARCHAR(10)  NOT NULL UNIQUE,
    description VARCHAR(100),
    CONSTRAINT ck_audit_event_code CHECK (event_code IN ('INSERT','UPDATE','DELETE'))
);

INSERT INTO autoaudit.audit_event (id_event, event_code, description) VALUES
    (1, 'INSERT', 'Inserción de fila'),
    (2, 'UPDATE', 'Actualización de fila'),
    (3, 'DELETE', 'Eliminación de fila')
ON CONFLICT (id_event) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Tablas auditadas
-- pk_columns: columnas de la PK de la tabla origen (se calcula al registrar).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS autoaudit.audited_table (
    id_table    BIGSERIAL    PRIMARY KEY,
    schema_name VARCHAR(63)  NOT NULL,
    table_name  VARCHAR(63)  NOT NULL,
    pk_columns  TEXT[]       NOT NULL DEFAULT '{}',
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ,
    CONSTRAINT uq_audited_table UNIQUE (schema_name, table_name)
);

-- ---------------------------------------------------------------------------
-- Columnas auditadas
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS autoaudit.audited_column (
    id_column   BIGSERIAL    PRIMARY KEY,
    id_table    BIGINT       NOT NULL REFERENCES autoaudit.audited_table(id_table) ON DELETE CASCADE,
    column_name VARCHAR(63)  NOT NULL,
    data_type   VARCHAR(100) NOT NULL,
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT uq_audited_column UNIQUE (id_table, column_name)
);

-- ---------------------------------------------------------------------------
-- Configuración: columna + evento
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS autoaudit.audit_config (
    id_config    BIGSERIAL    PRIMARY KEY,
    id_column    BIGINT       NOT NULL REFERENCES autoaudit.audited_column(id_column) ON DELETE CASCADE,
    id_event     SMALLINT     NOT NULL REFERENCES autoaudit.audit_event(id_event),
    is_enabled   BOOLEAN      NOT NULL DEFAULT TRUE,
    trigger_name VARCHAR(63),                       -- lo llena el generador al instalar
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by   VARCHAR(63),
    CONSTRAINT uq_audit_config UNIQUE (id_column, id_event)
);

-- ---------------------------------------------------------------------------
-- Registro de triggers instalados (como máximo uno por tabla y evento)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS autoaudit.trigger_registry (
    id_trigger     BIGSERIAL    PRIMARY KEY,
    id_table       BIGINT       NOT NULL REFERENCES autoaudit.audited_table(id_table) ON DELETE CASCADE,
    trigger_name   VARCHAR(63)  NOT NULL,
    event_type     VARCHAR(10)  NOT NULL,
    function_name  VARCHAR(63)  NOT NULL,
    is_installed   BOOLEAN      NOT NULL DEFAULT FALSE,
    installed_at   TIMESTAMPTZ,
    sql_definition TEXT,
    last_error     TEXT,                            -- último error al generar/instalar
    CONSTRAINT uq_trigger_registry_name  UNIQUE (id_table, trigger_name),
    CONSTRAINT uq_trigger_registry_event UNIQUE (id_table, event_type)
);

-- ---------------------------------------------------------------------------
-- Usuarios y estaciones
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS autoaudit.audit_user (
    id_user      BIGSERIAL    PRIMARY KEY,
    db_username  VARCHAR(63)  NOT NULL UNIQUE,
    display_name VARCHAR(120),
    is_admin     BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS autoaudit.audit_station (
    id_station  BIGSERIAL    PRIMARY KEY,
    hostname    VARCHAR(255),
    ip_address  INET,
    os_info     VARCHAR(100),
    last_seen   TIMESTAMPTZ,
    -- una estación = (hostname, ip); NULLs cuentan como iguales (PG 15+)
    CONSTRAINT uq_audit_station UNIQUE NULLS NOT DISTINCT (hostname, ip_address)
);

-- ---------------------------------------------------------------------------
-- Bitácora centralizada: UNA FILA POR COLUMNA AUDITADA QUE CAMBIÓ.
--   change_id agrupa las filas que pertenecen a la misma operación sobre la fila origen.
--   old_value / new_value son JSONB escalares (ej. 1500.00, "texto", null).
--   id_config e id_table pasan a NULL si se borra la configuración (ON DELETE SET NULL);
--   schema_name / table_name / column_name / pk_values preservan el dato original.
-- ---------------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS autoaudit.seq_change_id;

CREATE TABLE IF NOT EXISTS autoaudit.audit_log (
    id_log       BIGSERIAL    PRIMARY KEY,
    change_id    BIGINT       NOT NULL,
    id_config    BIGINT       REFERENCES autoaudit.audit_config(id_config) ON DELETE SET NULL,
    id_table     BIGINT       REFERENCES autoaudit.audited_table(id_table) ON DELETE SET NULL,
    id_user      BIGINT       REFERENCES autoaudit.audit_user(id_user),
    id_station   BIGINT       REFERENCES autoaudit.audit_station(id_station),
    operation    VARCHAR(10)  NOT NULL CHECK (operation IN ('INSERT','UPDATE','DELETE')),
    operation_ts TIMESTAMPTZ  NOT NULL DEFAULT clock_timestamp(),
    schema_name  VARCHAR(63)  NOT NULL,
    table_name   VARCHAR(63)  NOT NULL,
    column_name  VARCHAR(63)  NOT NULL,
    pk_values    JSONB,
    old_value    JSONB,
    new_value    JSONB,
    client_ip    INET,
    session_id   TEXT
);

-- Índices B-tree para las consultas históricas (sin GIN: encarece cada INSERT)
CREATE INDEX IF NOT EXISTS idx_audit_log_ts      ON autoaudit.audit_log (operation_ts DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_user    ON autoaudit.audit_log (id_user, operation_ts DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_column  ON autoaudit.audit_log (schema_name, table_name, column_name, operation_ts DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_change  ON autoaudit.audit_log (change_id);
-- Opcional, solo si se consulta mucho por PK (cuesta rendimiento de escritura):
-- CREATE INDEX idx_audit_log_pk ON autoaudit.audit_log USING GIN (pk_values jsonb_path_ops);

-- ---------------------------------------------------------------------------
-- Caché del diccionario de datos
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS autoaudit.db_catalog_cache (
    id_cache     BIGSERIAL    PRIMARY KEY,
    schema_name  VARCHAR(63)  NOT NULL,
    table_name   VARCHAR(63)  NOT NULL,
    column_name  VARCHAR(63)  NOT NULL,
    data_type    VARCHAR(100) NOT NULL,
    is_nullable  BOOLEAN      NOT NULL,
    is_pk        BOOLEAN      NOT NULL DEFAULT FALSE,
    refreshed_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT uq_catalog_cache UNIQUE (schema_name, table_name, column_name)
);

-- ---------------------------------------------------------------------------
-- Bitácora de solo-append: bloquea UPDATE / DELETE / TRUNCATE (incluso al dueño).
-- Única excepción: la acción ON DELETE SET NULL de las FK (id_config, id_table),
-- que solo pone esos dos campos en NULL.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION autoaudit.fn_audit_log_immutable()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF TG_OP = 'UPDATE'
       AND (to_jsonb(NEW) - 'id_config' - 'id_table') = (to_jsonb(OLD) - 'id_config' - 'id_table')
       AND (NEW.id_config IS NULL OR NEW.id_config IS NOT DISTINCT FROM OLD.id_config)
       AND (NEW.id_table  IS NULL OR NEW.id_table  IS NOT DISTINCT FROM OLD.id_table)
    THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'autoaudit.audit_log es de solo-append: % no permitido', TG_OP
        USING ERRCODE = 'insufficient_privilege';
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_log_immutable ON autoaudit.audit_log;
CREATE TRIGGER trg_audit_log_immutable
    BEFORE UPDATE OR DELETE ON autoaudit.audit_log
    FOR EACH ROW EXECUTE FUNCTION autoaudit.fn_audit_log_immutable();

DROP TRIGGER IF EXISTS trg_audit_log_no_truncate ON autoaudit.audit_log;
CREATE TRIGGER trg_audit_log_no_truncate
    BEFORE TRUNCATE ON autoaudit.audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION autoaudit.fn_audit_log_immutable();

COMMENT ON TABLE autoaudit.audit_log IS
    'Bitácora centralizada (solo-append). Una fila por columna auditada que cambió. Solo fn_audit_generic inserta.';
