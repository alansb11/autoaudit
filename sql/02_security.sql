-- ============================================================================
-- AutoAudit · 02_security.sql
-- Roles y verificación de administrador.
--   autoaudit_admin  : puede configurar auditoría (registrar tablas, instalar triggers).
--   autoaudit_reader : solo puede consultar la bitácora y los reportes.
-- Para dar acceso:  GRANT autoaudit_admin TO mi_usuario;
-- ============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'autoaudit_admin') THEN
        CREATE ROLE autoaudit_admin NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'autoaudit_reader') THEN
        CREATE ROLE autoaudit_reader NOLOGIN;
    END IF;
END $$;

-- Quien instala el sistema queda registrado como administrador
INSERT INTO autoaudit.audit_user (db_username, display_name, is_admin)
VALUES (session_user, 'Instalador', TRUE)
ON CONFLICT (db_username) DO UPDATE SET is_admin = TRUE;

-- ---------------------------------------------------------------------------
-- assert_admin(): lanza error si quien llama (session_user, el usuario real que
-- inició sesión) no es superusuario ni miembro de autoaudit_admin.
-- Además marca is_admin = TRUE en audit_user para quien sí lo es.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION autoaudit.assert_admin()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, autoaudit, pg_temp
AS $$
BEGIN
    IF pg_has_role(session_user, 'autoaudit_admin', 'MEMBER')
       OR EXISTS (SELECT 1 FROM pg_roles WHERE rolname = session_user AND rolsuper)
    THEN
        INSERT INTO autoaudit.audit_user AS au (db_username, is_admin)
        VALUES (session_user, TRUE)
        ON CONFLICT (db_username) DO UPDATE SET is_admin = TRUE
            WHERE NOT au.is_admin;
        RETURN;
    END IF;

    RAISE EXCEPTION 'AutoAudit: el usuario "%" no tiene privilegios de administrador (rol autoaudit_admin)', session_user
        USING ERRCODE = 'insufficient_privilege';
END;
$$;
