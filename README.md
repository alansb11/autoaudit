# AutoAudit — Sistema de auditoría automatizado

Proyecto final del curso **Bases de Datos 1** · Universidad Mariano Gálvez de Guatemala
Facultad de Ingeniería en Sistemas de Información y Ciencias de la Computación

AutoAudit es un sistema de auditoría **configurable** para PostgreSQL. El administrador elige qué tablas y
columnas vigilar y para qué eventos (INSERT, UPDATE, DELETE); el sistema **genera e instala los triggers**
automáticamente y registra cada cambio en una **bitácora centralizada de solo-append** con valores
antiguos y nuevos, usuario, estación, IP y marca temporal. Incluye una interfaz web para configurar,
consultar el historial y exportar reportes.

## Contenido

1. [Características](#características)
2. [Requisitos](#requisitos)
3. [Estructura del repositorio](#estructura-del-repositorio)
4. [Instalación rápida](#instalación-rápida)
5. [Uso desde SQL](#uso-desde-sql)
6. [Interfaz web](#interfaz-web)
7. [Pruebas](#pruebas)
8. [Rendimiento](#rendimiento)
9. [Decisiones de diseño](#decisiones-de-diseño)
10. [Limitaciones conocidas](#limitaciones-conocidas)
11. [Documentación](#documentación)
12. [Solución de problemas](#solución-de-problemas)

## Características

- Selección de tablas y columnas a partir del **diccionario de datos** de PostgreSQL (`pg_catalog`).
- Activación por **tipo de operación** (INSERT / UPDATE / DELETE) y por columna.
- **Generación dinámica de triggers** AFTER (uno por tabla y evento habilitado), registrados en `trigger_registry`
  y verificados contra `pg_trigger` (`v_trigger_status`).
- **Validación** de existencia de tablas, columnas y eventos antes de activar; errores capturados por evento.
- Bitácora con una fila por columna modificada: valor antiguo, valor nuevo, usuario real, estación, IP, PK de la fila,
  configuración usada y marca temporal. **Se conserva aunque se borre la fila origen.**
- Seguridad: solo administradores configuran; la bitácora no admite escritura directa ni modificación.
- Consultas históricas **parametrizadas** por usuario, columna o fila, con rango de fechas y orden cronológico.
- Interfaz web (Flask) con exportación a **CSV y JSON**.

## Requisitos

| Componente | Versión |
|---|---|
| PostgreSQL | 18 (objetivo del proyecto). Mínimo 15; probado en 16 y 18.6 |
| Sistema operativo | Ubuntu 26.04 LTS (objetivo) o Windows |
| Python (solo interfaz web) | 3.10 o superior |
| Cliente | `psql` |

## Estructura del repositorio

```
sql/                        Scripts de la base de datos (se instalan con install.sql)
  install.sql               Ejecuta los scripts 01–08 en orden
  01_schema.sql             Tablas, índices y protección de la bitácora
  02_security.sql           Roles autoaudit_admin / autoaudit_reader y verificación de administrador
  03_catalog.sql            Consultas al diccionario de datos (v_db_tables, v_db_columns, caché)
  04_config.sql             Registrar tablas/columnas, activar y desactivar auditoría (con validación)
  05_trigger_function.sql   Función genérica que ejecutan los triggers
  06_trigger_generator.sql  Generador dinámico de triggers + estado real (v_trigger_status)
  07_queries.sql            Consultas históricas parametrizadas
  08_grants.sql             Permisos
  90_demo.sql               Ejemplo de uso (opcional)
  91_usuarios_demo.sql      Usuarios de demostración para la interfaz (opcional)
tests/
  01_funcional.sql          Pruebas de INSERT / UPDATE / DELETE, permisos y errores
  02_rendimiento.sql        Pruebas de rendimiento con volumen creciente
  03_interfaz.py            Pruebas automáticas de la interfaz web
app/                        Interfaz web (Flask): app.py, requirements.txt, templates/
docs/                       Documentación técnica (Word)
```

## Instalación rápida

Todos los comandos se ejecutan **desde la carpeta del proyecto**.

### Windows (`cmd`)

Si `psql` no se reconoce, agréguelo al `PATH` de esa ventana (ajuste el número de versión):

```
set PATH=C:\Program Files\PostgreSQL\18\bin;%PATH%
set PGCLIENTENCODING=UTF8
```

Cree la base de datos e instale AutoAudit:

```
psql -U postgres -c "CREATE DATABASE autoaudit_db;"
psql -U postgres -d autoaudit_db -f sql\install.sql
```

### Ubuntu / Linux

```
sudo -u postgres createdb autoaudit_db
sudo -u postgres psql -d autoaudit_db -f sql/install.sql
```

(Si el usuario `postgres` no puede leer la carpeta, copie `sql/` a `/tmp` o use `psql -h localhost -U postgres`.)

La instalación termina con `AutoAudit instalado correctamente.` El instalador se detiene ante el primer error.
Es **idempotente**: puede ejecutarse de nuevo sin problema.

### Demostración (opcional)

```
psql -h 127.0.0.1 -U postgres -d autoaudit_db -f sql\90_demo.sql
```

Se usa `-h 127.0.0.1` para que la bitácora registre la IP (por socket local `client_ip` queda vacío).

## Uso desde SQL

Los siguientes comandos los ejecuta un **administrador**: superusuario o miembro de `autoaudit_admin`.

```sql
-- Dar permisos
GRANT autoaudit_admin  TO mi_usuario;    -- configurar
GRANT autoaudit_reader TO otro_usuario;  -- solo consultar

-- Ver el diccionario de datos
SELECT * FROM autoaudit.v_db_tables;
SELECT column_name, data_type, is_pk FROM autoaudit.v_db_columns
WHERE schema_name = 'public' AND table_name = 'clientes';

-- Activar la auditoría (valida, configura e instala los triggers)
SELECT * FROM autoaudit.enable_audit('public', 'clientes', ARRAY['nombre','email','saldo']);
SELECT * FROM autoaudit.enable_audit('public', 'clientes', ARRAY['saldo'], ARRAY['UPDATE','DELETE']);

-- Estado real de los triggers
SELECT * FROM autoaudit.v_trigger_status;

-- Consultar el historial
SELECT * FROM autoaudit.history_by_user('juan');
SELECT * FROM autoaudit.history_by_user('juan', '2026-11-01', '2026-12-01', 500, FALSE);
SELECT * FROM autoaudit.history_by_column('public', 'clientes', 'saldo');
SELECT * FROM autoaudit.history_by_row('public', 'clientes', '{"id": 1}');

-- Desactivar
SELECT * FROM autoaudit.disable_audit('public', 'clientes');                          -- tabla completa
SELECT * FROM autoaudit.disable_audit('public', 'clientes', ARRAY['saldo']);          -- una columna
SELECT * FROM autoaudit.disable_audit('public', 'clientes', NULL, ARRAY['DELETE']);   -- un evento
```

Exportar desde `psql`:

```
\copy (SELECT * FROM autoaudit.history_by_column('public','clientes','saldo',NULL,NULL,NULL,FALSE)) TO 'saldo.csv' CSV HEADER
```

Para registrar el nombre de la estación, la aplicación cliente puede enviar:
`SET autoaudit.hostname = 'PC-01'; SET autoaudit.os_info = 'Windows 11';`

## Interfaz web

Crear los usuarios de demostración y levantar la aplicación:

```
psql -U postgres -d autoaudit_db -f sql\91_usuarios_demo.sql
cd app
python -m venv venv
venv\Scripts\activate            (Linux: source venv/bin/activate)
pip install -r requirements.txt
set AA_DB_NAME=autoaudit_db      (Linux: export AA_DB_NAME=autoaudit_db)
python app.py
```

Abra **http://127.0.0.1:5000** e inicie sesión con un usuario **de PostgreSQL**:

| Usuario | Contraseña | Puede |
|---|---|---|
| `admin_demo` | `admin123` | Configurar la auditoría y consultar el historial |
| `lector_demo` | `lector123` | Solo consultar y exportar el historial |
| `usuario_demo` | `usuario123` | Nada de AutoAudit (usuario de negocio) |

> Estas contraseñas son solo para demostración. Cámbielas en cualquier otro entorno.

Variables de entorno opcionales: `AA_DB_HOST`, `AA_DB_PORT`, `AA_DB_NAME`, `AA_PORT`.

La aplicación se conecta con las credenciales del usuario, así que **los permisos los hace cumplir PostgreSQL**
(roles `autoaudit_admin` y `autoaudit_reader`). Pantallas: Inicio, Configuración (tablas, columnas y eventos),
Triggers (estado real), Historial (por usuario, columna o fila) y exportación a CSV/JSON.

## Pruebas

Las pruebas dejan registros en la bitácora, que es de solo-append y no se puede vaciar. Úselas en una **base aparte**
y elimínela al terminar.

**Funcionales (INSERT, UPDATE, DELETE, permisos, errores):**

```
psql -U postgres -c "CREATE DATABASE autoaudit_test;"
psql -U postgres -d autoaudit_test -f sql\install.sql
psql -U postgres -d autoaudit_test -f tests\01_funcional.sql
```

Debe terminar con `TODAS LAS PRUEBAS PASARON` (11 casos con verificaciones `ASSERT`).

**Interfaz web (25 verificaciones):** con el entorno de Python activo y los usuarios de demostración creados en esa base:

```
psql -U postgres -d autoaudit_test -f sql\91_usuarios_demo.sql
set AA_DB_NAME=autoaudit_test
python tests\03_interfaz.py
```

**Rendimiento con volumen creciente:** vea la cabecera de `tests/02_rendimiento.sql`.

```
psql -U postgres -c "CREATE DATABASE autoaudit_perf;"
psql -U postgres -d autoaudit_perf -f sql\install.sql
psql -U postgres -d autoaudit_perf -v volumenes=1000,10000,100000 -f tests\02_rendimiento.sql
```

Sin `-v volumenes=...` corre 1 000, 10 000, 100 000 y 1 000 000 de filas (varios minutos y ~3 GB de disco).
Guarde la salida con `> resultados_rendimiento.txt` y elimine la base al terminar:
`psql -U postgres -c "DROP DATABASE autoaudit_perf;"`.

## Rendimiento

Resultados medidos en PostgreSQL 18.6 (Windows), auditando 3 columnas:

- El costo extra por fila es de unos **0.4 a 0.9 ms** en INSERT, UPDATE y DELETE, y crece de forma casi lineal con el volumen.
  Para operaciones normales (una o pocas filas por transacción) el impacto es inferior a 1 ms.
- En cargas masivas el costo es considerable: un millón de INSERT pasa de **8.6 s a 885 s**.
  Para cargas masivas planificadas conviene desactivar la auditoría de la tabla y reactivarla al terminar.
- Con 7.7 millones de filas en la bitácora (3.2 GB con índices), las consultas por columna tardan ~3 ms y por usuario ~0.2 s.

El análisis completo está en el documento de `docs/`.

## Decisiones de diseño

- **Una fila de bitácora por columna modificada**, agrupadas por `change_id`, cada una con su `id_config`.
- **Usuario real = `session_user`.** Dentro de una función `SECURITY DEFINER`, `current_user` sería el dueño de la función.
- **Bitácora de solo-append:** bloquea UPDATE, DELETE y TRUNCATE incluso al dueño; solo `fn_audit_generic` inserta.
- **Si no se puede escribir la bitácora, el cambio original se revierte:** nunca hay cambios sin auditoría.
- **La configuración solo se escribe mediante funciones** que exigen ser administrador y validan contra el catálogo.
- **Solo se guardan las columnas auditadas** (más la PK); el resto de la fila nunca se copia a la bitácora.
- **Sin índices GIN** sobre los valores: encarecen cada escritura. El índice sobre `pk_values` es opcional.

## Limitaciones conocidas

- No audita `TRUNCATE`. Un superusuario podría desactivar los triggers de la tabla de negocio.
- Por socket local, `client_ip` queda NULL; conectarse por TCP (`-h 127.0.0.1`) para registrarla.
- El nombre de host y el sistema operativo de la estación los debe enviar la aplicación cliente.
- La consulta por fila (PK) no tiene índice por defecto.
- Las sesiones de la interfaz viven en memoria de un solo proceso y no hay HTTPS: uso académico.
- No hay retención ni archivado automático de la bitácora.

## Documentación

La documentación técnica completa (diagrama entidad-relación, diccionario de datos, manual de configuración,
procedimiento de instalación y despliegue de triggers, pruebas y rendimiento) está en
[`docs/AutoAudit_Documentacion_Tecnica.docx`](docs/AutoAudit_Documentacion_Tecnica.docx).

## Solución de problemas

| Problema | Solución |
|---|---|
| `psql` no se reconoce (Windows) | `set PATH=C:\Program Files\PostgreSQL\18\bin;%PATH%` en esa ventana de `cmd` |
| Error de autenticación | Revise la contraseña del usuario `postgres` (no se ve al escribirla) |
| Tildes raras en la consola de Windows | Es solo cómo `cmd` dibuja el texto; ejecute `chcp 65001` para verlas bien |
| `invalid byte sequence for encoding UTF8` | No escriba tildes dentro de un comando de `cmd`; use un archivo `.sql` |
| `No module named flask` | Active el entorno: `venv\Scripts\activate` dentro de `app` |
| La IP sale vacía en la bitácora | Conéctese por TCP: `psql -h 127.0.0.1 ...` |
| `permission denied for schema public` | PostgreSQL 15+ no deja crear tablas en `public` a usuarios comunes; cree la tabla con un superusuario |

## Autor

[Nombre del estudiante] · [Carné] · Guatemala, noviembre de 2026
