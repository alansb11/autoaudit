-- ============================================================================
-- AutoAudit · 90_demo.sql  (opcional, NO forma parte de la instalación)
-- Ejemplo de uso completo con una tabla de negocio.
--   Ejecutar como administrador (superusuario o miembro de autoaudit_admin).
--   Para ver la IP en la bitácora conéctese por TCP:  psql -h 127.0.0.1 ...
-- ============================================================================

DROP TABLE IF EXISTS public.clientes CASCADE;
CREATE TABLE public.clientes (
    id         SERIAL PRIMARY KEY,
    nombre     VARCHAR(100) NOT NULL,
    email      VARCHAR(150),
    saldo      NUMERIC(12,2) DEFAULT 0,
    activo     BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- 1) Ver qué hay disponible en el diccionario de datos
SELECT * FROM autoaudit.v_db_tables;
SELECT column_name, data_type, is_nullable, is_pk
FROM autoaudit.v_db_columns WHERE schema_name = 'public' AND table_name = 'clientes';

-- 2) Activar auditoría (valida existencia, configura e instala los triggers)
SELECT * FROM autoaudit.enable_audit('public', 'clientes', ARRAY['nombre','email','saldo','activo']);

-- 3) Identificar la estación (opcional; lo normal es que lo envíe la aplicación cliente)
SET autoaudit.hostname = 'PC-DEMO-01';
SET autoaudit.os_info  = 'Ubuntu 26.04';

-- 4) Operaciones
INSERT INTO public.clientes (nombre, email, saldo) VALUES
    ('Ana López', 'ana@mail.com', 1500.00), ('Carlos Ruiz', 'carlos@mail.com', 3200.50);
UPDATE public.clientes SET saldo = 1800.00, email = 'ana.lopez@mail.com' WHERE nombre = 'Ana López';
DELETE FROM public.clientes WHERE nombre = 'Carlos Ruiz';

-- 5) Consultas históricas
SELECT operation_ts, operation, db_username, column_name, old_value, new_value
FROM autoaudit.history_by_column('public', 'clientes', 'saldo', NULL, NULL, NULL, FALSE);

SELECT * FROM autoaudit.history_by_user(session_user);
SELECT * FROM autoaudit.history_by_row('public', 'clientes', '{"id": 1}');

-- 6) Estado real de los triggers
SELECT * FROM autoaudit.v_trigger_status;

-- 7) Apagar
-- SELECT * FROM autoaudit.disable_audit('public', 'clientes');                      -- tabla completa
-- SELECT * FROM autoaudit.disable_audit('public', 'clientes', ARRAY['saldo']);      -- solo una columna
-- SELECT * FROM autoaudit.disable_audit('public', 'clientes', NULL, ARRAY['DELETE']); -- solo un evento
