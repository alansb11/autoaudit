-- ============================================================================
-- AutoAudit · tests/02_rendimiento.sql
-- Pruebas de rendimiento con volumen creciente de registros auditados.
--
-- Compara dos tablas idénticas: perf_base (SIN auditoría) y perf_aud (CON auditoría
-- de nombre, email y saldo en INSERT/UPDATE/DELETE) para cada volumen y operación,
-- y luego mide las consultas históricas sobre la bitácora resultante.
--
-- Uso (en una base APARTE, con AutoAudit ya instalado, como superusuario):
--   psql -U postgres -c "CREATE DATABASE autoaudit_perf;"
--   psql -U postgres -d autoaudit_perf -f install.sql
--   psql -U postgres -d autoaudit_perf -f 02_rendimiento.sql
-- Volúmenes personalizados (por defecto 1000, 10000, 100000 y 1000000):
--   psql -U postgres -d autoaudit_perf -v volumenes=1000,10000 -f 02_rendimiento.sql
-- Guardar resultados en un archivo:
--   psql -U postgres -d autoaudit_perf -f 02_rendimiento.sql > resultados.txt
--
-- IMPORTANTE: la bitácora es de solo-append, así que estas pruebas la llenan de
-- millones de filas que no se pueden borrar. Después de la prueba elimine la base:
--   psql -U postgres -c "DROP DATABASE autoaudit_perf;"
-- Con 1 millón de filas puede tardar varios minutos y ocupar ~2 GB de disco.
-- ============================================================================
\set ON_ERROR_STOP on
\set QUIET on
\if :{?volumenes}
\else
  \set volumenes 1000,10000,100000,1000000
\endif
SELECT set_config('perf.volumenes', :'volumenes', false) \gset

DROP TABLE IF EXISTS public.perf_base, public.perf_aud, public.perf_raw CASCADE;
CREATE TABLE public.perf_base (
    id     INTEGER PRIMARY KEY,
    nombre VARCHAR(100) NOT NULL,
    email  VARCHAR(150),
    saldo  NUMERIC(12,2),
    nota   TEXT
);
CREATE TABLE public.perf_aud (LIKE public.perf_base INCLUDING ALL);
CREATE TABLE public.perf_raw (
    volumen INTEGER, operacion TEXT, variante TEXT, ms NUMERIC, filas_log BIGINT
);

-- Activa auditoría solo en perf_aud (3 columnas, 3 eventos)
SELECT count(*) AS triggers_instalados
FROM autoaudit.enable_audit('public', 'perf_aud', ARRAY['nombre','email','saldo']);

-- Ejecuta una sentencia, hace COMMIT y registra tiempo (ms) y filas escritas en la bitácora
CREATE OR REPLACE PROCEDURE public.perf_medir(p_n INT, p_op TEXT, p_var TEXT, p_sql TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    t0 TIMESTAMPTZ;
    s0 BIGINT;
BEGIN
    SELECT CASE WHEN is_called THEN last_value ELSE 0 END INTO s0 FROM autoaudit.audit_log_id_log_seq;
    t0 := clock_timestamp();
    EXECUTE p_sql;
    COMMIT;
    INSERT INTO public.perf_raw
    SELECT p_n, p_op, p_var,
           round(extract(epoch FROM clock_timestamp() - t0) * 1000, 1),
           (SELECT CASE WHEN is_called THEN last_value ELSE 0 END FROM autoaudit.audit_log_id_log_seq) - s0;
    COMMIT;
END $$;

\echo 'Ejecutando pruebas (puede tardar)...'
SET autoaudit.hostname = 'PC-RENDIMIENTO';

DO $$
DECLARE
    v_n INT;
    v_t TEXT;
BEGIN
    FOREACH v_n IN ARRAY string_to_array(current_setting('perf.volumenes'), ',')::INT[] LOOP
        TRUNCATE public.perf_base, public.perf_aud;
        COMMIT;
        FOREACH v_t IN ARRAY ARRAY['perf_base','perf_aud'] LOOP
            CALL public.perf_medir(v_n, '1 INSERT', v_t,
                format('INSERT INTO public.%I SELECT g, ''cliente ''||g, ''c''||g||''@mail.com'', mod(g,1000), ''nota'' FROM generate_series(1,%s) g', v_t, v_n));
        END LOOP;
        FOREACH v_t IN ARRAY ARRAY['perf_base','perf_aud'] LOOP
            CALL public.perf_medir(v_n, '2 UPDATE columna auditada (saldo)', v_t,
                format('UPDATE public.%I SET saldo = saldo + 1', v_t));
        END LOOP;
        FOREACH v_t IN ARRAY ARRAY['perf_base','perf_aud'] LOOP
            CALL public.perf_medir(v_n, '3 UPDATE columna NO auditada (nota)', v_t,
                format('UPDATE public.%I SET nota = ''modificada''', v_t));
        END LOOP;
        FOREACH v_t IN ARRAY ARRAY['perf_base','perf_aud'] LOOP
            CALL public.perf_medir(v_n, '4 DELETE', v_t,
                format('DELETE FROM public.%I', v_t));
        END LOOP;
    END LOOP;
END $$;

\unset QUIET
\echo ''
\echo '=== RESULTADO: tiempo por operación (ms) sin y con auditoría ==='
SELECT volumen AS filas,
       substr(operacion, 3)                                       AS operacion,
       max(ms) FILTER (WHERE variante = 'perf_base')              AS ms_sin_auditoria,
       max(ms) FILTER (WHERE variante = 'perf_aud')               AS ms_con_auditoria,
       round(max(ms) FILTER (WHERE variante = 'perf_aud')
           / NULLIF(max(ms) FILTER (WHERE variante = 'perf_base'), 0), 1) AS veces_mas_lento,
       round((max(ms) FILTER (WHERE variante = 'perf_aud')
            - max(ms) FILTER (WHERE variante = 'perf_base')) * 1000.0 / volumen, 1) AS microseg_extra_por_fila,
       max(filas_log) FILTER (WHERE variante = 'perf_aud')        AS filas_en_bitacora
FROM public.perf_raw
GROUP BY volumen, operacion
ORDER BY volumen, operacion;

-- ---------------------------------------------------------------------------
-- Consultas históricas sobre la bitácora acumulada
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== Tamaño de la bitácora ==='
SELECT (SELECT count(*) FROM autoaudit.audit_log)                         AS filas_bitacora,
       pg_size_pretty(pg_total_relation_size('autoaudit.audit_log'))      AS tamano_total_con_indices,
       pg_size_pretty(pg_relation_size('autoaudit.audit_log'))            AS tamano_tabla;

ANALYZE autoaudit.audit_log;
\echo ''
\echo '=== Tiempo de consultas históricas (cada una muestra su "Time:") ==='
\timing on
\echo '-- Por usuario (últimas 1000 filas)'
SELECT count(*) FROM autoaudit.history_by_user(session_user);
\echo '-- Por usuario con rango de fechas de la última hora, orden cronológico'
SELECT count(*) FROM autoaudit.history_by_user(session_user, now() - interval '1 hour', now(), 1000, FALSE);
\echo '-- Por columna (public.perf_aud.saldo, últimas 1000 filas)'
SELECT count(*) FROM autoaudit.history_by_column('public', 'perf_aud', 'saldo');
\echo '-- Por fila (PK) -- no hay índice sobre pk_values (ver nota en 01_schema.sql)'
SELECT count(*) FROM autoaudit.history_by_row('public', 'perf_aud', '{"id": 500}');
\timing off

-- Limpieza de objetos de prueba (la bitácora no se puede borrar: elimine la base)
DROP PROCEDURE public.perf_medir(INT, TEXT, TEXT, TEXT);
DROP TABLE public.perf_base, public.perf_aud, public.perf_raw;
\echo ''
\echo 'Fin. Recuerde eliminar la base de pruebas: DROP DATABASE autoaudit_perf;'
