-- ============================================================================
-- AutoAudit · 91_usuarios_demo.sql  (opcional, solo para demostración/pruebas)
-- Crea tres usuarios para probar la interfaz web. CAMBIE las contraseñas en producción.
--   admin_demo   / admin123    -> rol autoaudit_admin  (configura y consulta)
--   lector_demo  / lector123   -> rol autoaudit_reader (solo consulta el historial)
--   usuario_demo / usuario123  -> sin rol AutoAudit    (usuario normal de negocio)
-- ============================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'admin_demo') THEN
        CREATE ROLE admin_demo LOGIN PASSWORD 'admin123';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lector_demo') THEN
        CREATE ROLE lector_demo LOGIN PASSWORD 'lector123';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'usuario_demo') THEN
        CREATE ROLE usuario_demo LOGIN PASSWORD 'usuario123';
    END IF;
END $$;

GRANT autoaudit_admin  TO admin_demo;
GRANT autoaudit_reader TO lector_demo;

-- PostgreSQL 15+ no deja crear tablas en "public" por defecto; solo para la demo:
GRANT CREATE ON SCHEMA public TO admin_demo;
