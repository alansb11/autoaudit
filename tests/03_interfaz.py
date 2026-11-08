"""
AutoAudit · tests/03_interfaz.py
Prueba automática de la interfaz web contra una base real.
Requisitos: AutoAudit instalado (sql/install.sql) y sql/91_usuarios_demo.sql ejecutado.
Uso (desde la carpeta del proyecto):
    set AA_DB_NAME=autoaudit_db        (Windows)   /   export AA_DB_NAME=autoaudit_db   (Linux)
    python tests\\03_interfaz.py
Crea y elimina una tabla public.t_app_<número>. Deja registros en la bitácora (es de solo-append).
"""
import csv, io, json, os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "app"))
import psycopg
import app as aa

DB = aa.DB
ADMIN, LECTOR, NORMAL = ("admin_demo", "admin123"), ("lector_demo", "lector123"), ("usuario_demo", "usuario123")
fails = []
TBL = f"t_app_{int(time.time())}"      # nombre único: la bitácora no se puede borrar entre corridas

def check(cond, msg):
    print(("  OK   " if cond else "  FALLO ") + msg)
    if not cond:
        fails.append(msg)

def login(creds):
    c = aa.app.test_client()
    r = c.post("/login", data={"user": creds[0], "password": creds[1]})
    return c, r

def csrf(c):
    return aa.SESSIONS[c.get_cookie("aa_session").value]["csrf"]

def sconn(creds=None, autocommit=True):
    creds = creds or ("postgres", os.getenv("PGPASSWORD", ""))
    return psycopg.connect(**DB, user=creds[0], password=creds[1], autocommit=autocommit)

# ---- preparación (con el usuario administrador demo, que además es quien crea la tabla de prueba)
adm = sconn(ADMIN)
adm.execute(f"CREATE TABLE public.{TBL} (id SERIAL PRIMARY KEY, nombre TEXT, saldo NUMERIC(12,2), nota TEXT)")
adm.execute(f"GRANT ALL ON public.{TBL} TO usuario_demo")
adm.execute(f"GRANT USAGE ON SEQUENCE public.{TBL}_id_seq TO usuario_demo")

print("1. Inicio de sesión")
c, r = login((ADMIN[0], "incorrecta"))
check(r.status_code == 401, "contraseña incorrecta es rechazada")
c, r = aa.app.test_client(), None
cn, r = login(NORMAL)
check(r.status_code == 302, "usuario normal puede iniciar sesión")
check(cn.get("/config").status_code == 403, "usuario sin rol NO accede a /config")
check(cn.get("/history").status_code == 403, "usuario sin rol NO accede a /history")
check(cn.get("/triggers").status_code == 403, "usuario sin rol NO accede a /triggers")

print("2. Configuración (administrador)")
ca, r = login(ADMIN)
check(r.status_code == 302, "administrador inicia sesión")
page = ca.get("/config")
check(page.status_code == 200 and TBL.encode() in page.data, "lista las tablas del diccionario de datos")
check(ca.post(f"/config/public/{TBL}", data={"chk": ["nombre|INSERT"]}).status_code == 400,
      "POST sin token CSRF es rechazado")
data = {"csrf": csrf(ca), "action": "save",
        "chk": ["nombre|INSERT", "nombre|UPDATE", "nombre|DELETE", "saldo|INSERT", "saldo|UPDATE", "saldo|DELETE"]}
r = ca.post(f"/config/public/{TBL}", data=data, follow_redirects=True)
check(r.status_code == 200 and "Configuración guardada" in r.get_data(as_text=True), "guarda la configuración")
n = adm.execute(f"SELECT count(*) FROM pg_trigger WHERE tgrelid='public.{TBL}'::regclass AND NOT tgisinternal").fetchone()[0]
check(n == 3, "se instalaron 3 triggers en PostgreSQL")
html = ca.get(f"/config/public/{TBL}").get_data(as_text=True)
check('value="saldo|UPDATE"' in html and 'checked' in html, "la pantalla refleja la configuración guardada")
r = ca.post("/config/public/no_existe", data={"csrf": csrf(ca), "action": "save", "chk": ["x|INSERT"]})
check(r.status_code == 404, "tabla inexistente devuelve 404")
check(ca.get("/triggers").status_code == 200, "pantalla de triggers")

print("3. Cambios de negocio hechos por otro usuario")
nu = sconn(NORMAL)
nu.execute(f"INSERT INTO public.{TBL} (nombre, saldo, nota) VALUES ('Ana', 1500, 'x')")
nu.execute(f"UPDATE public.{TBL} SET saldo = 1800 WHERE nombre = 'Ana'")
nu.execute(f"DELETE FROM public.{TBL} WHERE nombre = 'Ana'")

print("4. Historial (lector)")
cl, r = login(LECTOR)
check(cl.get("/config").status_code == 403, "lector NO accede a /config")
check(cl.post(f"/config/public/{TBL}", data={"csrf": csrf(cl), "action": "disable"}).status_code == 403,
      "lector NO puede desactivar auditoría")
r = cl.get("/history?modo=usuario&usuario=usuario_demo&buscar=1")
t = r.get_data(as_text=True)
check(r.status_code == 200 and "1800.00" in t and "1500.00" in t, "consulta por usuario muestra valores antiguo y nuevo")
r = cl.get(f"/history?modo=columna&esquema=public&tabla={TBL}&columna=saldo&orden=asc&buscar=1")
t = r.get_data(as_text=True)
check(t.index("INSERT") < t.index("UPDATE") < t.index("DELETE"), "consulta por columna en orden cronológico")
r = cl.get(f'/history?modo=fila&esquema=public&tabla={TBL}&pk={{"id":1}}&buscar=1')
check("DELETE" in r.get_data(as_text=True), "consulta por fila (PK) y el DELETE conserva datos")
r = cl.get(f"/history?modo=fila&tabla={TBL}&pk=no-es-json&buscar=1")
check("JSON" in r.get_data(as_text=True), "PK inválida muestra mensaje claro")
q = f"modo=columna&esquema=public&tabla={TBL}&columna=saldo&orden=asc"
r = cl.get(f"/history/export.csv?{q}")
rows = list(csv.DictReader(io.StringIO(r.get_data(as_text=True).lstrip("\ufeff"))))
check(r.status_code == 200 and len(rows) == 3 and rows[0]["operation"] == "INSERT", "exporta CSV (3 filas)")
r = cl.get(f"/history/export.json?{q}")
js = json.loads(r.get_data(as_text=True))
check(len(js) == 3 and js[1]["old_value"] == 1500 and js[1]["new_value"] == 1800, "exporta JSON con valores correctos")
check("attachment" in r.headers["Content-Disposition"], "descarga como archivo adjunto")

print("5. Desactivar auditoría (administrador)")
r = ca.post(f"/config/public/{TBL}", data={"csrf": csrf(ca), "action": "disable"}, follow_redirects=True)
n = adm.execute(f"SELECT count(*) FROM pg_trigger WHERE tgrelid='public.{TBL}'::regclass AND NOT tgisinternal").fetchone()[0]
check(n == 0, "se eliminaron los triggers")
check(cl.get(f"/history/export.json?{q}").status_code == 200 and
      len(json.loads(cl.get(f"/history/export.json?{q}").get_data(as_text=True))) == 3,
      "la bitácora se conserva tras desactivar")

print("6. Cerrar sesión")
r = ca.post("/logout", data={"csrf": csrf(ca)})
check(r.status_code == 302 and ca.get("/config").status_code == 302, "logout invalida la sesión")

adm.execute(f"DROP TABLE public.{TBL}")
print()
print("TODAS LAS PRUEBAS DE LA INTERFAZ PASARON" if not fails else f"{len(fails)} PRUEBA(S) FALLARON")
sys.exit(1 if fails else 0)
