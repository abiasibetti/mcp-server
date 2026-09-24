#!/usr/bin/env bash
# =============================================================================
# install-deploy.sh — prepara il server MCP per essere gestito dalla pipeline GitHub
#
# Uso (dalla cartella server/ del repository, sul server MCP):
#   sudo ./install-deploy.sh --plan-key mcp_plan.pub --apply-key mcp_apply.pub --from IP_RUNNER
#
#   --plan-key   chiave pubblica usata dalla pipeline per il PIANO (sola lettura)
#   --apply-key  chiave pubblica usata dalla pipeline per l'APPLICAZIONE
#   --from       IP o reti da cui il runner si collega (es. 192.168.10.30 o 192.168.10.0/24,10.0.0.5)
#
# Cosa fa:
#   - installa mcp-admin e mcp-reconcile in /usr/local/sbin (se serve esegue mcp-admin setup)
#   - crea l'utente mcp-deploy (senza password)
#   - regola sudo: mcp-deploy può eseguire SOLO "mcp-reconcile plan" e "mcp-reconcile apply"
#   - chiavi autorizzate di root in /etc/ssh/mcp_deploy_keys, ciascuna vincolata
#     al proprio comando (plan o apply) e agli IP del runner
#   - blocco sshd dedicato: solo chiave, niente shell interattiva né forwarding
# Rieseguibile: aggiorna script, chiavi e configurazione.
# =============================================================================
set -euo pipefail

PLAN_KEY="" APPLY_KEY="" FROM=""
DEPLOY_USER="mcp-deploy"
KEYS_FILE="/etc/ssh/mcp_deploy_keys"
SSHD_DROPIN="/etc/ssh/sshd_config.d/20-mcp-deploy.conf"
SUDOERS_FILE="/etc/sudoers.d/mcp-deploy"
RECONCILE="/usr/local/sbin/mcp-reconcile"
HERE="$(cd "$(dirname "$0")" && pwd)"

die()  { echo "ERRORE: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "ATTENZIONE: $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan-key)  PLAN_KEY="${2:-}";  shift 2 ;;
    --apply-key) APPLY_KEY="${2:-}"; shift 2 ;;
    --from)      FROM="${2:-}";      shift 2 ;;
    *) die "opzione sconosciuta: $1" ;;
  esac
done

[[ ${EUID} -eq 0 ]] || die "esegui come root"
[[ -n "${PLAN_KEY}" && -n "${APPLY_KEY}" && -n "${FROM}" ]] || die "servono --plan-key, --apply-key e --from"
[[ "${FROM}" =~ ^[0-9a-fA-F.:/,*]+$ ]] || die "--from non valido: usa IP o reti separati da virgole"
command -v python3 >/dev/null || die "python3 non trovato"
command -v sudo >/dev/null || die "sudo non trovato"
[[ -f "${HERE}/mcp-admin" && -f "${HERE}/mcp-reconcile" ]] || die "mcp-admin e mcp-reconcile devono stare accanto a questo script"

read_key() {
  local line
  [[ -r "$1" ]] || die "file non leggibile: $1"
  line="$(grep -Em1 '^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) [A-Za-z0-9+/]+={0,3}( [^[:cntrl:]]*)?$' "$1" || true)"
  [[ -n "${line}" ]] || die "nessuna chiave pubblica valida in $1"
  printf '%s' "${line}"
}
plan_line="$(read_key "${PLAN_KEY}")"
apply_line="$(read_key "${APPLY_KEY}")"
[[ "$(awk '{print $2}' <<<"${plan_line}")" != "$(awk '{print $2}' <<<"${apply_line}")" ]] \
  || die "le chiavi plan e apply devono essere diverse"

# ----------------------------------------------------------------------------- script
install -m 700 -o root -g root "${HERE}/mcp-admin" /usr/local/sbin/mcp-admin
install -m 700 -o root -g root "${HERE}/mcp-reconcile" "${RECONCILE}"
info "installati /usr/local/sbin/mcp-admin e ${RECONCILE}"
[[ -x /usr/local/bin/mcp-gateway ]] || /usr/local/sbin/mcp-admin setup

# ----------------------------------------------------------------------------- utente
if ! id "${DEPLOY_USER}" &>/dev/null; then
  useradd --system --create-home --home-dir "/var/lib/${DEPLOY_USER}" \
          --shell /bin/sh --comment "Deploy MCP (pipeline GitHub)" "${DEPLOY_USER}"
  info "creato utente ${DEPLOY_USER}"
fi
usermod -p '*' "${DEPLOY_USER}"

# ----------------------------------------------------------------------------- sudo
tmp="$(mktemp)"
cat >"${tmp}" <<EOF
# Gestito da install-deploy.sh: la pipeline può eseguire solo il reconcile
Defaults:${DEPLOY_USER} !requiretty, !use_pty
${DEPLOY_USER} ALL=(root) NOPASSWD: ${RECONCILE} plan, ${RECONCILE} apply
EOF
visudo -cf "${tmp}" >/dev/null || { rm -f "${tmp}"; die "regola sudoers non valida"; }
install -m 440 -o root -g root "${tmp}" "${SUDOERS_FILE}"
rm -f "${tmp}"
info "regola sudo: ${SUDOERS_FILE}"

# ----------------------------------------------------------------------------- chiavi
cat >"${KEYS_FILE}.new" <<EOF
restrict,from="${FROM}",command="/usr/bin/sudo -n ${RECONCILE} plan" ${plan_line}
restrict,from="${FROM}",command="/usr/bin/sudo -n ${RECONCILE} apply" ${apply_line}
EOF
chown root:root "${KEYS_FILE}.new"
chmod 644 "${KEYS_FILE}.new"
mv -f "${KEYS_FILE}.new" "${KEYS_FILE}"
command -v restorecon >/dev/null 2>&1 && restorecon "${KEYS_FILE}" 2>/dev/null || true
info "chiavi della pipeline: ${KEYS_FILE} (accesso solo da ${FROM})"

# ----------------------------------------------------------------------------- sshd
backup=""
[[ -f "${SSHD_DROPIN}" ]] && { backup="$(mktemp)"; cp -p "${SSHD_DROPIN}" "${backup}"; }
cat >"${SSHD_DROPIN}" <<EOF
# Gestito da install-deploy.sh — utente della pipeline: solo chiave, comando forzato
Match User ${DEPLOY_USER}
    AuthorizedKeysFile ${KEYS_FILE}
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitTTY no
    DisableForwarding yes
    PermitUserRC no
Match all
EOF
chmod 644 "${SSHD_DROPIN}"
if ! sshd -t; then
  if [[ -n "${backup}" ]]; then mv -f "${backup}" "${SSHD_DROPIN}"; else rm -f "${SSHD_DROPIN}"; fi
  die "configurazione sshd non valida: modifica annullata"
fi
[[ -n "${backup}" ]] && rm -f "${backup}"
systemctl reload sshd 2>/dev/null || systemctl reload ssh
info "configurazione sshd: ${SSHD_DROPIN}"

allow="$(sshd -T 2>/dev/null | awk 'tolower($1)=="allowgroups"{$1=""; print}')"
if [[ -n "${allow}" && " ${allow} " != *" ${DEPLOY_USER} "* ]]; then
  warn "AllowGroups è attivo (${allow# }): aggiungi il gruppo ${DEPLOY_USER} in 00-hardening.conf"
fi
[[ -x /usr/local/bin/uv ]] || warn "uv non trovato in /usr/local/bin: serve per i server con install.method: pip"

echo
info "fatto. Fingerprint da salvare nella variabile GitHub MCP_SSH_KNOWN_HOSTS:"
k=/etc/ssh/ssh_host_ed25519_key.pub
if [[ -f "${k}" ]]; then
  echo "    $(hostname -f 2>/dev/null || hostname),$(hostname -I 2>/dev/null | awk '{print $1}') $(awk '{print $1, $2}' "${k}")"
else
  warn "chiave host ed25519 non trovata: ricavala con ssh-keyscan -t ed25519 dal runner"
fi
