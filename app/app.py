"""
AutoAudit · interfaz web (Flask)

Inicia sesión con un USUARIO REAL DE POSTGRESQL: la aplicación se conecta a la base con
esas credenciales, así que los permisos los hace cumplir la base de datos (roles
autoaudit_admin / autoaudit_reader), no la aplicación.

Módulos:  /config  (admin)  selección de tablas, columnas y eventos + instalación de triggers
          /triggers (admin) estado real de los triggers
          /history  (lector o admin) consulta histórica por usuario, columna o fila + exportación CSV/JSON

Variables de entorno (opcionales): AA_DB_HOST, AA_DB_PORT, AA_DB_NAME, AA_HOST, AA_PORT
"""
import csv
import io
import json
import os
import secrets
from datetime import date, datetime, timedelta
from decimal import Decimal
from functools import wraps

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import set_json_loads
from flask import (Flask, Response, abort, flash, g, make_response, redirect,
                   render_template, request, url_for)

DB = dict(host=os.getenv("AA_DB_HOST", "localhost"),
          port=int(os.getenv("AA_DB_PORT", "5432")),
          dbname=os.getenv("AA_DB_NAME", "autoaudit_db"))

app = Flask(__name__)
app.secret_key = os.getenv("AA_SECRET", secrets.token_hex(16))   # solo firma los mensajes flash

# Sesiones en memoria del servidor: la cookie guarda únicamente un token aleatorio,
# nunca la contraseña. (Suficiente para un proyecto académico de un solo proceso.)
SESSIONS = {}

# Los números de las columnas JSONB se leen como Decimal para conservar el valor exacto
# (1800.00 y no 1800.0): importante al auditar saldos y montos.
set_json_loads(lambda data: json.loads(data, parse_float=Decimal))


def json_default(o):
    return float(o) if isinstance(o, Decimal) else str(o)


EVENTS = ("INSERT", "UPDATE", "DELETE")
HIST_COLS = ["id_log", "change_id", "operation_ts", "operation", "db_username", "hostname",
             "client_ip", "schema_name", "table_name", "column_name", "pk_values",
             "old_value", "new_value", "id_config", "session_id"]
PAGE_CAP = 500           # filas que se muestran en pantalla
EXPORT_CAP = 1_000_000   # tope de seguridad en exportaciones


# ---------------------------------------------------------------- utilidades
def db():
    s = g.sess
    return psycopg.connect(**DB, user=s["user"], password=s["password"],
                           row_factory=dict_row, connect_timeout=5)


@app.before_request
def load_session():
    g.sess = SESSIONS.get(request.cookies.get("aa_session"))
    if request.method == "POST" and request.endpoint != "login":
        token = request.form.get("csrf", "")
        if not g.sess or not secrets.compare_digest(token, g.sess["csrf"]):
            abort(400, "Token CSRF inválido o sesión expirada")


@app.context_processor
def inject():
    return {"sess": g.get("sess")}


def need(role):
    """role = None (cualquier sesión), 'reader' (lector o admin) o 'admin'."""
    def deco(fn):
        @wraps(fn)
        def wrapper(*a, **kw):
            s = g.sess
            if not s:
                return redirect(url_for("login"))
            if role == "admin" and not s["is_admin"]:
                abort(403, "Se requiere el rol autoaudit_admin")
            if role == "reader" and not (s["is_admin"] or s["is_reader"]):
                abort(403, "Se requiere el rol autoaudit_reader o autoaudit_admin")
            return fn(*a, **kw)
        return wrapper
    return deco


@app.template_filter("val")
def fmt_val(v):
    if v is None:
        return "—"
    if isinstance(v, (dict, list)):
        return json.dumps(v, ensure_ascii=False, default=json_default)
    if isinstance(v, str):
        return v
    return str(v)


@app.errorhandler(psycopg.Error)
def db_error(e):
    msg = getattr(getattr(e, "diag", None), "message_primary", None) or str(e)
    status = 403 if isinstance(e, psycopg.errors.InsufficientPrivilege) else 400
    return render_template("error.html", status=status, msg=msg), status


@app.errorhandler(400)
@app.errorhandler(403)
@app.errorhandler(404)
def http_error(e):
    return render_template("error.html", status=e.code, msg=e.description), e.code


# ---------------------------------------------------------------- sesión
@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        user, password = request.form.get("user", "").strip(), request.form.get("password", "")
        try:
            with psycopg.connect(**DB, user=user, password=password, row_factory=dict_row,
                                 connect_timeout=5) as conn:
                row = conn.execute("""
                    SELECT session_user::text AS u,
                           (pg_has_role(session_user, 'autoaudit_admin', 'MEMBER')
                            OR (SELECT rolsuper FROM pg_roles WHERE rolname = session_user)) AS is_admin,
                           pg_has_role(session_user, 'autoaudit_reader', 'MEMBER') AS is_reader
                """).fetchone()
        except psycopg.Error as e:
            flash("No se pudo iniciar sesión: " +
                  (getattr(getattr(e, "diag", None), "message_primary", None) or str(e).strip()), "error")
            return render_template("login.html", dbname=DB["dbname"]), 401
        token = secrets.token_urlsafe(32)
        SESSIONS[token] = dict(user=row["u"], password=password, is_admin=bool(row["is_admin"]),
                               is_reader=bool(row["is_reader"]), csrf=secrets.token_urlsafe(24))
        resp = make_response(redirect(url_for("index")))
        resp.set_cookie("aa_session", token, httponly=True, samesite="Lax")
        return resp
    return render_template("login.html", dbname=DB["dbname"])


@app.post("/logout")
def logout():
    SESSIONS.pop(request.cookies.get("aa_session"), None)
    resp = make_response(redirect(url_for("login")))
    resp.delete_cookie("aa_session")
    return resp


# ---------------------------------------------------------------- inicio
@app.route("/")
@need(None)
def index():
    tables, log_estimate = [], None
    with db() as conn:
        if g.sess["is_admin"]:
            tables = conn.execute("""
                SELECT t.schema_name, t.table_name, t.is_active,
                       (SELECT count(*) FROM autoaudit.trigger_registry r
                         WHERE r.id_table = t.id_table AND r.is_installed) AS triggers,
                       (SELECT count(*) FROM autoaudit.audited_column c
                         WHERE c.id_table = t.id_table AND c.is_active) AS columnas
                FROM autoaudit.audited_table t ORDER BY 1, 2""").fetchall()
        if g.sess["is_admin"] or g.sess["is_reader"]:
            log_estimate = conn.execute(
                "SELECT reltuples::bigint AS n FROM pg_class WHERE oid = 'autoaudit.audit_log'::regclass"
            ).fetchone()["n"]
    return render_template("index.html", tables=tables, log_estimate=log_estimate)


# ---------------------------------------------------------------- configuración
@app.route("/config")
@need("admin")
def config_list():
    with db() as conn:
        rows = conn.execute("""
            SELECT v.schema_name, v.table_name, (t.id_table IS NOT NULL) AS registrada,
                   COALESCE(t.is_active, FALSE) AS is_active,
                   (SELECT count(*) FROM autoaudit.audit_config cfg
                      JOIN autoaudit.audited_column ac ON ac.id_column = cfg.id_column
                     WHERE ac.id_table = t.id_table AND cfg.is_enabled AND ac.is_active) AS configs
            FROM autoaudit.v_db_tables v
            LEFT JOIN autoaudit.audited_table t
                   ON t.schema_name = v.schema_name AND t.table_name = v.table_name
            ORDER BY v.schema_name, v.table_name""").fetchall()
    return render_template("config_list.html", rows=rows)


def enabled_pairs(conn, schema, table, only_active):
    q = """SELECT ac.column_name, ev.event_code
           FROM autoaudit.audit_config cfg
           JOIN autoaudit.audited_column ac ON ac.id_column = cfg.id_column
           JOIN autoaudit.audit_event ev ON ev.id_event = cfg.id_event
           JOIN autoaudit.audited_table t ON t.id_table = ac.id_table
           WHERE t.schema_name = %s AND t.table_name = %s AND cfg.is_enabled"""
    if only_active:
        q += " AND ac.is_active AND t.is_active"
    return {(r["column_name"], r["event_code"]) for r in conn.execute(q, (schema, table))}


@app.route("/config/<schema>/<table>", methods=["GET", "POST"])
@need("admin")
def config_table(schema, table):
    with db() as conn:
        cols = conn.execute("""SELECT column_name, data_type, is_pk FROM autoaudit.v_db_columns
                               WHERE schema_name = %s AND table_name = %s
                               ORDER BY ordinal_position""", (schema, table)).fetchall()
        if not cols:
            abort(404, f"La tabla {schema}.{table} no existe en la base de datos")
        valid_cols = {c["column_name"] for c in cols}

        if request.method == "POST":
            if request.form.get("action") == "disable":
                res = conn.execute("SELECT * FROM autoaudit.disable_audit(%s, %s)", (schema, table)).fetchall()
                flash(f"Auditoría desactivada para {schema}.{table}. La bitácora existente se conserva.", "ok")
                for r in res:
                    flash(f"{r['status']}: {r['trigger_name']}", "info")
                return redirect(url_for("config_table", schema=schema, table=table))

            selected = set()
            for item in request.form.getlist("chk"):
                col, _, ev = item.rpartition("|")
                if col in valid_cols and ev in EVENTS:
                    selected.add((col, ev))
            if not selected:
                flash("Marque al menos una columna y un evento, o use «Desactivar auditoría».", "error")
                return redirect(url_for("config_table", schema=schema, table=table))

            current = enabled_pairs(conn, schema, table, only_active=False)
            conn.execute("SELECT autoaudit.register_table(%s, %s)", (schema, table))
            for col in sorted({c for c, _ in selected}):
                conn.execute("SELECT autoaudit.register_column(%s, %s, %s)", (schema, table, col))
            for col, ev in sorted(selected):
                conn.execute("SELECT autoaudit.set_audit_config(%s, %s, %s, %s, TRUE)", (schema, table, col, ev))
            for col, ev in sorted(current - selected):
                conn.execute("SELECT autoaudit.set_audit_config(%s, %s, %s, %s, FALSE)", (schema, table, col, ev))
            res = conn.execute("SELECT * FROM autoaudit.install_triggers(%s, %s)", (schema, table)).fetchall()
            errors = [r for r in res if r["status"] == "ERROR"]
            flash("Configuración guardada." if not errors else
                  "Configuración guardada, pero hubo errores al instalar triggers.", "error" if errors else "ok")
            for r in res:
                flash(f"{r['event_type']}: {r['status']} — {r['detail'] if r['status'] == 'ERROR' else r['trigger_name']}",
                      "error" if r["status"] == "ERROR" else "info")
            return redirect(url_for("config_table", schema=schema, table=table))

        enabled = enabled_pairs(conn, schema, table, only_active=True)
        status = conn.execute("""SELECT event_type, trigger_name, registry_says_installed, exists_in_postgres,
                                        in_sync, last_error FROM autoaudit.v_trigger_status
                                 WHERE schema_name = %s AND table_name = %s ORDER BY event_type""",
                              (schema, table)).fetchall()
    return render_template("config_table.html", schema=schema, table=table, cols=cols,
                           enabled=enabled, events=EVENTS, status=status)


@app.route("/triggers")
@need("admin")
def triggers():
    with db() as conn:
        rows = conn.execute("""SELECT * FROM autoaudit.v_trigger_status
                               ORDER BY schema_name, table_name, event_type""").fetchall()
    return render_template("triggers.html", rows=rows)


# ---------------------------------------------------------------- historial
def parse_filters(args):
    keys = ("modo", "usuario", "esquema", "tabla", "columna", "pk", "desde", "hasta", "limite", "orden")
    f = {k: (args.get(k) or "").strip() for k in keys}
    f["modo"] = f["modo"] or "usuario"
    f["esquema"] = f["esquema"] or "public"
    f["orden"] = f["orden"] or "desc"
    return f


def parse_limit(f):
    if not f["limite"]:
        return None
    try:
        n = int(f["limite"])
    except ValueError:
        raise ValueError("El límite debe ser un número entero")
    if n <= 0:
        raise ValueError("El límite debe ser mayor que cero")
    return n


def run_history(conn, f, limit):
    try:
        desde = date.fromisoformat(f["desde"]).isoformat() if f["desde"] else None
        hasta = (date.fromisoformat(f["hasta"]) + timedelta(days=1)).isoformat() if f["hasta"] else None
    except ValueError:
        raise ValueError("Fecha inválida")
    desc = f["orden"] != "asc"
    if f["modo"] == "usuario":
        if not f["usuario"]:
            raise ValueError("Indique el usuario")
        sql = "SELECT * FROM autoaudit.history_by_user(%s, %s::timestamptz, %s::timestamptz, %s::int, %s)"
        params = (f["usuario"], desde, hasta, limit, desc)
    elif f["modo"] == "columna":
        if not (f["tabla"] and f["columna"]):
            raise ValueError("Indique tabla y columna")
        sql = ("SELECT * FROM autoaudit.history_by_column(%s, %s, %s, %s::timestamptz, "
               "%s::timestamptz, %s::int, %s)")
        params = (f["esquema"], f["tabla"], f["columna"], desde, hasta, limit, desc)
    elif f["modo"] == "fila":
        if not f["tabla"]:
            raise ValueError("Indique la tabla")
        try:
            pk = json.loads(f["pk"])
            if not isinstance(pk, dict):
                raise ValueError
        except ValueError:
            raise ValueError('La clave primaria debe ser un JSON, por ejemplo {"id": 1}')
        sql = ("SELECT * FROM autoaudit.history_by_row(%s, %s, %s::jsonb, %s::timestamptz, "
               "%s::timestamptz, %s::int, %s)")
        params = (f["esquema"], f["tabla"], json.dumps(pk), desde, hasta, limit, desc)
    else:
        raise ValueError("Modo de consulta inválido")
    return conn.execute(sql, params).fetchall()


@app.route("/history")
@need("reader")
def history():
    f = parse_filters(request.args)
    rows, truncated, searched = [], False, "buscar" in request.args
    with db() as conn:
        users = [r["db_username"] for r in conn.execute("SELECT db_username FROM autoaudit.audit_user ORDER BY 1")]
        if searched:
            try:
                lim = parse_limit(f)
                fetch = PAGE_CAP + 1 if (lim is None or lim > PAGE_CAP) else lim
                rows = run_history(conn, f, fetch)
                truncated = len(rows) > PAGE_CAP
                rows = rows[:PAGE_CAP]
            except ValueError as e:
                flash(str(e), "error")
                searched = False
    return render_template("history.html", f=f, rows=rows, truncated=truncated, searched=searched,
                           users=users, query=request.query_string.decode())


def cell(v):
    if v is None:
        return ""
    if isinstance(v, (dict, list)):
        return json.dumps(v, ensure_ascii=False, default=json_default)
    if isinstance(v, datetime):
        return v.isoformat(sep=" ")
    return str(v)


@app.route("/history/export.<fmt>")
@need("reader")
def history_export(fmt):
    if fmt not in ("csv", "json"):
        abort(404)
    f = parse_filters(request.args)
    try:
        lim = parse_limit(f)
        with db() as conn:
            rows = run_history(conn, f, min(lim or EXPORT_CAP, EXPORT_CAP))
    except ValueError as e:
        abort(400, str(e))
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    if fmt == "csv":
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(HIST_COLS)
        for r in rows:
            w.writerow([cell(r[c]) for c in HIST_COLS])
        body, mime = "\ufeff" + buf.getvalue(), "text/csv; charset=utf-8"   # BOM: Excel respeta UTF-8
    else:
        body = json.dumps([{c: r[c] for c in HIST_COLS} for r in rows],
                          ensure_ascii=False, indent=2, default=json_default)
        mime = "application/json; charset=utf-8"
    return Response(body, mimetype=mime.split(";")[0],
                    headers={"Content-Disposition": f"attachment; filename=autoaudit_{stamp}.{fmt}",
                             "Content-Type": mime})


if __name__ == "__main__":
    app.run(host=os.getenv("AA_HOST", "127.0.0.1"), port=int(os.getenv("AA_PORT", "5000")), debug=False)
