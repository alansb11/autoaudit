-- ============================================================================
-- AutoAudit · install.sql  — instala todo en orden.
--   psql -U postgres -d tu_base -f install.sql
-- (ejecutar como superusuario o como dueño de las tablas que se vayan a auditar)
-- ============================================================================
\set ON_ERROR_STOP on
\ir 01_schema.sql
\ir 02_security.sql
\ir 03_catalog.sql
\ir 04_config.sql
\ir 05_trigger_function.sql
\ir 06_trigger_generator.sql
\ir 07_queries.sql
\ir 08_grants.sql
\echo 'AutoAudit instalado correctamente.'
