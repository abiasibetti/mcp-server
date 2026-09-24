#!/usr/bin/env python3
"""
build_state.py — legge config/servers.yaml, config/users.yaml e keys/*.pub e produce
lo stato desiderato in JSON per mcp-reconcile.

    python3 scripts/build_state.py validate   controlla i file e stampa un riepilogo
    python3 scripts/build_state.py plan       JSON senza segreti (solo i loro nomi)
    python3 scripts/build_state.py apply      JSON con i segreti letti da SECRETS_JSON

In modalità apply la variabile SECRETS_JSON deve contenere ${{ toJSON(secrets) }}.
Il JSON viene scritto solo su stdout (da inviare in pipe a ssh): non salvarlo mai su disco.
I messaggi e gli errori vanno su stderr e non contengono mai valori segreti.
"""
import datetime
import json
import os
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML non installato: pip install pyyaml")

ROOT = Path(__file__).resolve().parent.parent
SERVERS_FILE = ROOT / "config" / "servers.yaml"
USERS_FILE = ROOT / "config" / "users.yaml"
KEYS_DIR = ROOT / "keys"

RE_SERVER = re.compile(r"[a-z][a-z0-9-]{0,19}")
RE_USER = re.compile(r"[a-z_][a-z0-9_-]{0,31}")
RE_ENV = re.compile(r"[A-Z_][A-Z0-9_]{0,63}")
RE_SECRET = re.compile(r"[A-Z_][A-Z0-9_]{0,99}")
RE_FILE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
RE_SHA256 = re.compile(r"[0-9a-f]{64}")
RE_KEY = re.compile(
    r"(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)|"
    r"sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) "
    r"([A-Za-z0-9+/]{16,}={0,3})(?: [\x21-\x7e ]{0,100})?"
)
RESERVED_FILES = {"run.sh", ".mcp-managed.json", "bin", "venv", "python"}

errors = []


def err(msg):
    errors.append(msg)


def load_yaml(path):
    if not path.is_file():
        sys.exit(f"file mancante: {path.relative_to(ROOT)}")
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    if not isinstance(data, dict):
        sys.exit(f"{path.relative_to(ROOT)}: il contenuto deve essere un oggetto YAML")
    return data


def scalar(v):
    """Normalizza i valori YAML: true -> "true", 55000 -> "55000"."""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, str):
        return v
    return None


def norm_value(where, key, v, secrets_used):
    s = scalar(v)
    if s is not None:
        return s
    if isinstance(v, dict) and set(v) == {"secret"} and isinstance(v["secret"], str) and RE_SECRET.fullmatch(v["secret"]):
        secrets_used.add(v["secret"])
        return {"secret": v["secret"]}
    err(f"{where}: valore non valido per {key} (usa una stringa o {{ secret: NOME_SECRET }})")
    return ""


def norm_expire(where, v):
    if v is None:
        return None
    if isinstance(v, datetime.date):
        return v.strftime("%Y%m%d")
    s = str(v).replace("-", "")
    if re.fullmatch(r"[0-9]{8}", s):
        try:
            datetime.datetime.strptime(s, "%Y%m%d")
            return s
        except ValueError:
            pass
    err(f"{where}: expire non valido (usa AAAA-MM-GG)")
    return None


def read_pubkey(user, rel):
    path = (ROOT / rel).resolve()
    if KEYS_DIR.resolve() not in path.parents:
        err(f"utente {user}: la chiave deve stare nella cartella keys/")
        return ""
    if not path.is_file():
        err(f"utente {user}: file chiave mancante {rel}")
        return ""
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if RE_KEY.fullmatch(line):
            return line
    err(f"utente {user}: nessuna chiave pubblica valida in {rel} (niente opzioni, una chiave per riga)")
    return ""


def build():
    scfg = load_yaml(SERVERS_FILE)
    ucfg = load_yaml(USERS_FILE)
    secrets_used = set()

    policy = scfg.get("policy") or {}
    maxdel = policy.get("max_user_deletions", 3)
    if not isinstance(maxdel, int) or maxdel < 0:
        err("policy.max_user_deletions deve essere un intero >= 0")

    servers = {}
    for name, s in (scfg.get("servers") or {}).items():
        where = f"server {name}"
        if not isinstance(name, str) or not RE_SERVER.fullmatch(name):
            err(f"{where}: nome non valido (minuscole, cifre, '-', max 20)")
            continue
        s = s or {}
        state = s.get("state", "present")
        if state not in ("present", "absent"):
            err(f"{where}: state deve essere present o absent")
        if state == "absent":
            servers[name] = {"state": "absent"}
            continue

        inst = s.get("install") or {"method": "none"}
        method = inst.get("method", "none")
        if method == "binary":
            if not str(inst.get("url", "")).startswith("https://"):
                err(f"{where}: install.url deve iniziare con https://")
            if "<" in str(inst.get("url", "")):
                err(f"{where}: install.url contiene ancora un segnaposto")
            if not RE_SHA256.fullmatch(str(inst.get("sha256", ""))):
                err(f"{where}: install.sha256 obbligatorio (64 caratteri esadecimali)")
            if not RE_FILE.fullmatch(str(inst.get("name", ""))):
                err(f"{where}: install.name non valido")
            inst = {"method": "binary", "url": inst.get("url"), "sha256": inst.get("sha256"), "name": inst.get("name")}
        elif method == "pip":
            pkg = str(inst.get("package", ""))
            if not pkg or "<" in pkg:
                err(f"{where}: install.package mancante o con segnaposto")
            elif "==" not in pkg:
                err(f"{where}: fissa la versione del pacchetto (es. nome==1.2.3)")
            inst = {"method": "pip", "package": pkg, "python": str(inst.get("python", "3.13"))}
        elif method == "none":
            inst = {"method": "none"}
        else:
            err(f"{where}: install.method deve essere binary, pip o none")

        cmd = s.get("command")
        if not isinstance(cmd, list) or not cmd or not all(isinstance(c, str) for c in cmd):
            err(f"{where}: command deve essere una lista di stringhe")
            cmd = ["/bin/false"]
        elif not (cmd[0].startswith("/") or cmd[0].startswith("{dir}/")):
            err(f"{where}: command[0] deve essere un percorso assoluto o iniziare con {{dir}}/")

        env = {}
        for k, v in (s.get("env") or {}).items():
            if not isinstance(k, str) or not RE_ENV.fullmatch(k):
                err(f"{where}: nome variabile non valido {k!r}")
                continue
            env[k] = norm_value(where, k, v, secrets_used)

        files = {}
        for fname, v in (s.get("files") or {}).items():
            if not isinstance(fname, str) or not RE_FILE.fullmatch(fname) or fname in RESERVED_FILES or fname.endswith(".env"):
                err(f"{where}: nome file non valido {fname!r}")
                continue
            files[fname] = norm_value(where, fname, v, secrets_used)

        servers[name] = {"state": "present", "install": inst, "command": cmd, "env": env, "files": files}

    present = {n for n, s in servers.items() if s["state"] == "present"}
    users = {}
    for u, spec in (ucfg.get("users") or {}).items():
        where = f"utente {u}"
        spec = spec or {}
        if not isinstance(u, str) or not RE_USER.fullmatch(u) or u.startswith("mcp-"):
            err(f"{where}: nome non valido")
            continue
        srv = spec.get("servers")
        if not isinstance(srv, list) or not srv:
            err(f"{where}: servers deve contenere almeno un server")
            srv = []
        for x in srv:
            if x not in present:
                err(f"{where}: server {x!r} non dichiarato in servers.yaml o dismesso")
        enabled = spec.get("enabled", True)
        if not isinstance(enabled, bool):
            err(f"{where}: enabled deve essere true o false")
        users[u] = {
            "servers": sorted(set(srv)),
            "enabled": enabled,
            "key": read_pubkey(u, spec.get("key_file", f"keys/{u}.pub")),
            "expire": norm_expire(where, spec.get("expire")),
        }

    state = {"version": 1, "policy": {"max_user_deletions": maxdel}, "servers": servers, "users": users}
    return state, secrets_used


def resolve_secrets(state, secrets_used):
    try:
        available = json.loads(os.environ.get("SECRETS_JSON", ""))
    except ValueError:
        sys.exit("SECRETS_JSON mancante o non valido (serve ${{ toJSON(secrets) }})")
    missing = sorted(n for n in secrets_used if not available.get(n))
    if missing:
        sys.exit("secret mancanti nell'environment GitHub: " + ", ".join(missing))
    for s in state["servers"].values():
        for section in ("env", "files"):
            for k, v in (s.get(section) or {}).items():
                if isinstance(v, dict):
                    v["value"] = available[v["secret"]]


def main():
    mode = sys.argv[1] if len(sys.argv) == 2 else ""
    if mode not in ("validate", "plan", "apply"):
        sys.exit(__doc__)
    state, secrets_used = build()
    if errors:
        print("Errori nella configurazione:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)

    if mode == "validate":
        live = [n for n, s in state["servers"].items() if s["state"] == "present"]
        print(f"Configurazione valida: {len(live)} server attivi, {len(state['users'])} utenti.", file=sys.stderr)
        print("Secret richiesti: " + (", ".join(sorted(secrets_used)) or "nessuno"), file=sys.stderr)
        return
    if mode == "apply":
        resolve_secrets(state, secrets_used)
    json.dump(state, sys.stdout)


if __name__ == "__main__":
    main()
