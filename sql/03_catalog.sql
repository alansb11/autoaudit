-- ============================================================================
-- AutoAudit · 03_catalog.sql
-- Consultas al diccionario de datos de PostgreSQL (pg_catalog).
--   v_db_tables   : tablas de usuario disponibles para auditar.
--   v_db_columns  : columnas con tipo, nulabilidad y si forman parte de la PK.
--   refresh_catalog_cache(): copia lo anterior a db_catalog_cache (para la UI).
-- Excluye esquemas del sistema y el propio esquema autoaudit.
-- ============================================================================

CREATE OR REPLACE VIEW autoaudit.v_db_tables AS
SELECT n.nspname::varchar(63) AS schema_name,
       c.relname::varchar(63) AS table_name,
       c.oid                  AS table_oid
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p')                     -- tablas normales y particionadas
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'autoaudit')
  AND n.nspname NOT LIKE 'pg\_%';

CREATE OR REPLACE VIEW autoaudit.v_db_columns AS
SELECT t.schema_name,
       t.table_name,
       a.attname::varchar(63)                       AS column_name,
       format_type(a.atttypid, a.atttypmod)::varchar(100) AS data_type,
       NOT a.attnotnull                             AS is_nullable,
       COALESCE(a.attnum = ANY (i.indkey::int2[]), FALSE) AS is_pk,
       a.attnum                                     AS ordinal_position
FROM autoaudit.v_db_tables t
JOIN pg_attribute a ON a.attrelid = t.table_oid
                   AND a.attnum > 0 AND NOT a.attisdropped
LEFT JOIN pg_index i ON i.indrelid = t.table_oid AND i.indisprimary;

CREATE OR REPLACE FUNCTION autoaudit.refresh_catalog_cache(p_schema TEXT DEFAULT NULL)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, autoaudit, pg_temp
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    PERFORM autoaudit.assert_admin();

    DELETE FROM autoaudit.db_catalog_cache
    WHERE p_schema IS NULL OR schema_name = p_schema;

    INSERT INTO autoaudit.db_catalog_cache
        (schema_name, table_name, column_name, data_type, is_nullable, is_pk, refreshed_at)
    SELECT schema_name, table_name, column_name, data_type, is_nullable, is_pk, now()
    FROM autoaudit.v_db_columns
    WHERE p_schema IS NULL OR schema_name = p_schema;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;
