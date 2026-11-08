-- ============================================================================
-- AutoAudit · tests/01_funcional.sql
-- Pruebas funcionales con verificaciones (ASSERT). Falla con error si algo no cumple.
--   psql -U postgres -d tu_base -f sql/install.sql
--   psql -U postgres -d tu_base -f tests/01_funcional.sql
-- Crea objetos de prueba (tabla public.t_clientes, roles aa_admin_t / aa_user_t) y los elimina al final.
-- ============================================================================
\set ON_ERROR_STOP on
\set QUIET on

-- ---------- preparación ----------
DROP TABLE IF EXISTS public.t_clientes CASCADE;
CREATE TABLE public.t_clientes (
    id     SERIAL PRIMARY KEY,
    nombre VARCHAR(100) NOT NULL,
    email  VARCHAR(150),
    saldo  NUMERIC(12,2) DEFAULT 0,
    nota   TEXT                                  -- columna que NO se audita
);
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='aa_admin_t') THEN CREATE ROLE aa_admin_t LOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='aa_user_t')  THEN CREATE ROLE aa_user_t  LOGIN; END IF;
END $$;
GRANT autoaudit_admin TO aa_admin_t;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.t_clientes TO aa_admin_t, aa_user_t;
GRANT USAGE ON SEQUENCE public.t_clientes_id_seq TO aa_admin_t, aa_user_t;

-- ---------- T1: solo un administrador puede configurar ----------
SET SESSION AUTHORIZATION aa_user_t;
DO $$ BEGIN
    BEGIN
        PERFORM autoaudit.register_table('public','t_clientes');
        RAISE EXCEPTION 'T1 FALLO: un usuario normal pudo configurar';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET SESSION AUTHORIZATION;
\echo 'T1 OK  usuario sin rol admin no puede ejecutar funciones de configuración'

-- ---------- T2: validación de existencia ----------
SET SESSION AUTHORIZATION aa_admin_t;
DO $$ BEGIN
    BEGIN PERFORM autoaudit.register_table('public','no_existe');
          RAISE EXCEPTION 'T2a FALLO'; EXCEPTION WHEN undefined_table THEN NULL; END;
    PERFORM autoaudit.register_table('public','t_clientes');
    BEGIN PERFORM autoaudit.register_column('public','t_clientes','columna_falsa');
          RAISE EXCEPTION 'T2b FALLO'; EXCEPTION WHEN undefined_column THEN NULL; END;
    BEGIN PERFORM autoaudit.set_audit_config('public','t_clientes','saldo','TRUNCATE');
          RAISE EXCEPTION 'T2c FALLO'; EXCEPTION WHEN raise_exception THEN NULL; END;
END $$;
\echo 'T2 OK  tabla/columna/evento inexistentes son rechazados'

-- ---------- activar auditoría (como admin) ----------
SELECT * FROM autoaudit.enable_audit('public','t_clientes', ARRAY['nombre','email','saldo']);
RESET SESSION AUTHORIZATION;

DO $$ BEGIN
    ASSERT (SELECT count(*) FROM autoaudit.trigger_registry tr JOIN autoaudit.audited_table t USING (id_table)
            WHERE t.table_name='t_clientes' AND tr.is_installed) = 3, 'T3 deben quedar 3 triggers';
    ASSERT (SELECT bool_and(in_sync) FROM autoaudit.v_trigger_status WHERE table_name='t_clientes'),
           'T3 registry desincronizado con pg_trigger';
    ASSERT (SELECT pk_columns FROM autoaudit.audited_table WHERE table_name='t_clientes') = ARRAY['id'],
           'T3 pk_columns incorrecto';
END $$;
\echo 'T3 OK  3 triggers instalados, registry sincronizado con pg_trigger, PK detectada'

-- ---------- T4: INSERT ----------
SET SESSION AUTHORIZATION aa_user_t;
SET autoaudit.hostname = 'PC-PRUEBA-01';
INSERT INTO public.t_clientes (nombre, email, saldo, nota) VALUES ('Ana', 'ana@mail.com', 1500, 'secreta');
RESET SESSION AUTHORIZATION;

DO $$ BEGIN
    ASSERT (SELECT count(*) FROM autoaudit.audit_log WHERE table_name='t_clientes' AND operation='INSERT') = 3,
           'T4 INSERT debe generar 1 fila por columna auditada (3)';
    ASSERT (SELECT count(DISTINCT change_id) FROM autoaudit.audit_log WHERE operation='INSERT' AND table_name='t_clientes') = 1,
           'T4 las 3 filas deben compartir change_id';
    ASSERT (SELECT bool_and(old_value IS NULL) FROM autoaudit.audit_log WHERE operation='INSERT' AND table_name='t_clientes'),
           'T4 old_value debe ser NULL en INSERT';
    ASSERT (SELECT new_value FROM autoaudit.audit_log WHERE operation='INSERT' AND column_name='saldo' AND table_name='t_clientes') = '1500.00'::jsonb,
           'T4 new_value de saldo';
    ASSERT (SELECT bool_and(id_config IS NOT NULL AND id_station IS NOT NULL AND id_table IS NOT NULL)
            FROM autoaudit.audit_log WHERE table_name='t_clientes'), 'T4 id_config/id_station/id_table deben llenarse';
    ASSERT (SELECT u.db_username FROM autoaudit.audit_log l JOIN autoaudit.audit_user u USING (id_user)
            WHERE l.table_name='t_clientes' LIMIT 1) = 'aa_user_t',
           'T4 el usuario debe ser quien hizo el cambio (session_user), no el dueño de la función';
    ASSERT (SELECT hostname FROM autoaudit.audit_station WHERE hostname='PC-PRUEBA-01') IS NOT NULL, 'T4 estación';
    ASSERT (SELECT pk_values FROM autoaudit.audit_log WHERE table_name='t_clientes' LIMIT 1) = '{"id": 1}'::jsonb,
           'T4 pk_values solo con la PK';
    ASSERT NOT EXISTS (SELECT 1 FROM autoaudit.audit_log WHERE column_name='nota'), 'T4 columna no auditada no debe aparecer';
END $$;
\echo 'T4 OK  INSERT: 1 fila por columna, usuario real, estación, config, PK; "nota" no auditada'

-- ---------- T5: UPDATE ----------
SET SESSION AUTHORIZATION aa_user_t;
UPDATE public.t_clientes SET saldo = 1800, email = 'ana.lopez@mail.com' WHERE id = 1;
UPDATE public.t_clientes SET nota = 'cambió solo la nota' WHERE id = 1;      -- no debe registrar nada
UPDATE public.t_clientes SET nombre = nombre WHERE id = 1;                    -- sin cambio real
RESET SESSION AUTHORIZATION;

DO $$ BEGIN
    ASSERT (SELECT count(*) FROM autoaudit.audit_log WHERE operation='UPDATE' AND table_name='t_clientes') = 2,
           'T5 UPDATE solo debe registrar columnas que cambiaron (saldo, email)';
    ASSERT (SELECT old_value FROM autoaudit.audit_log WHERE operation='UPDATE' AND column_name='saldo') = '1500.00'::jsonb
       AND (SELECT new_value FROM autoaudit.audit_log WHERE operation='UPDATE' AND column_name='saldo') = '1800.00'::jsonb,
           'T5 valor antiguo y nuevo de saldo';
END $$;
\echo 'T5 OK  UPDATE: captura valor antiguo y nuevo; ignora columnas no auditadas y updates sin cambio'

-- ---------- T6: DELETE preserva datos ----------
SET SESSION AUTHORIZATION aa_user_t;
DELETE FROM public.t_clientes WHERE id = 1;
RESET SESSION AUTHORIZATION;

DO $$ BEGIN
    ASSERT (SELECT count(*) FROM public.t_clientes) = 0, 'T6 la fila origen ya no existe';
    ASSERT (SELECT count(*) FROM autoaudit.audit_log WHERE operation='DELETE' AND table_name='t_clientes') = 3, 'T6 DELETE 3 filas';
    ASSERT (SELECT old_value FROM autoaudit.audit_log WHERE operation='DELETE' AND column_name='email') = '"ana.lopez@mail.com"'::jsonb,
           'T6 old_value del DELETE conserva el dato';
    ASSERT (SELECT bool_and(new_value IS NULL) FROM autoaudit.audit_log WHERE operation='DELETE'), 'T6 new_value NULL en DELETE';
END $$;
\echo 'T6 OK  DELETE: la bitácora conserva los datos aunque la fila origen ya no exista'

-- ---------- T7: consultas parametrizadas ----------
DO $$ BEGIN
    ASSERT (SELECT count(*) FROM autoaudit.history_by_user('aa_user_t')) = 8, 'T7 history_by_user (3+2+3)';
    ASSERT (SELECT count(*) FROM autoaudit.history_by_column('public','t_clientes','saldo')) = 3, 'T7 history_by_column saldo (ins, upd, del)';
    ASSERT (SELECT old_value FROM autoaudit.history_by_column('public','t_clientes','saldo',NULL,NULL,NULL,FALSE) LIMIT 1) IS NULL
       AND (SELECT operation FROM autoaudit.history_by_column('public','t_clientes','saldo',NULL,NULL,NULL,FALSE) LIMIT 1) = 'INSERT',
           'T7 orden cronológico ascendente';
    ASSERT (SELECT count(*) FROM autoaudit.history_by_row('public','t_clientes','{"id":1}')) = 8, 'T7 history_by_row';
    ASSERT (SELECT count(*) FROM autoaudit.history_by_user('aa_user_t', now() + interval '1 day')) = 0, 'T7 filtro de fechas';
END $$;
\echo 'T7 OK  consultas por usuario, columna y fila (con orden y rango de fechas)'

-- ---------- T8: bitácora de solo-append ----------
DO $$ BEGIN
    BEGIN UPDATE autoaudit.audit_log SET new_value = '0'::jsonb; RAISE EXCEPTION 'T8a FALLO';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
    BEGIN DELETE FROM autoaudit.audit_log; RAISE EXCEPTION 'T8b FALLO';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
    BEGIN TRUNCATE autoaudit.audit_log; RAISE EXCEPTION 'T8c FALLO';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SET SESSION AUTHORIZATION aa_user_t;
DO $$ BEGIN
    BEGIN PERFORM count(*) FROM autoaudit.audit_log; RAISE EXCEPTION 'T8d FALLO: usuario normal puede leer la bitácora';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
    BEGIN INSERT INTO autoaudit.audit_log (change_id, operation, schema_name, table_name, column_name)
          VALUES (1,'INSERT','x','x','x'); RAISE EXCEPTION 'T8e FALLO: usuario normal pudo escribir';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET SESSION AUTHORIZATION;
\echo 'T8 OK  bitácora inmutable (ni el dueño) y sin lectura/escritura directa para usuarios normales'

-- ---------- T9: desactivar parcialmente y reajustar triggers ----------
SET SESSION AUTHORIZATION aa_admin_t;
SELECT * FROM autoaudit.disable_audit('public','t_clientes', NULL, ARRAY['DELETE']);
RESET SESSION AUTHORIZATION;
DO $$ BEGIN
    ASSERT (SELECT count(*) FROM pg_trigger WHERE tgrelid='public.t_clientes'::regclass AND NOT tgisinternal) = 2,
           'T9 al desactivar DELETE debe quedar sin su trigger';
    ASSERT (SELECT bool_and(in_sync) FROM autoaudit.v_trigger_status WHERE table_name='t_clientes'), 'T9 sincronía';
END $$;
INSERT INTO public.t_clientes (nombre, saldo) VALUES ('Beto', 10);
DELETE FROM public.t_clientes WHERE nombre='Beto';
DO $$ BEGIN
    ASSERT (SELECT count(*) FROM autoaudit.audit_log WHERE operation='DELETE') = 3, 'T9 DELETE ya no se audita';
END $$;
\echo 'T9 OK  desactivar un evento elimina su trigger y deja de auditarse'

-- ---------- T10: manejo de errores en el generador ----------
DROP TABLE public.t_clientes;                 -- la tabla desaparece fuera de AutoAudit
SET SESSION AUTHORIZATION aa_admin_t;
DO $$ BEGIN
    BEGIN PERFORM * FROM autoaudit.install_triggers('public','t_clientes');
          RAISE EXCEPTION 'T10 FALLO'; EXCEPTION WHEN raise_exception THEN
          IF SQLERRM NOT LIKE '%ya no existe%' THEN RAISE; END IF; END;
END $$;
RESET SESSION AUTHORIZATION;
\echo 'T10 OK generador reporta error claro si la tabla ya no existe'

-- ---------- T11: historial se conserva aunque se elimine la configuración ----------
DELETE FROM autoaudit.audited_table WHERE table_name = 't_clientes';
DO $$ BEGIN
    ASSERT (SELECT count(*) FROM autoaudit.audit_log WHERE table_name='t_clientes') > 0, 'T11 la bitácora debe conservarse';
    ASSERT (SELECT bool_and(id_config IS NULL AND id_table IS NULL) FROM autoaudit.audit_log WHERE table_name='t_clientes'),
           'T11 id_config/id_table pasan a NULL (ON DELETE SET NULL)';
END $$;
\echo 'T11 OK historial intacto al borrar la configuración (FK pasa a NULL, nombres preservados)'

-- ---------- limpieza ----------
REVOKE ALL ON SCHEMA public FROM aa_admin_t, aa_user_t;
DROP ROLE aa_admin_t; DROP ROLE aa_user_t;
\echo ''
\echo 'TODAS LAS PRUEBAS PASARON'
