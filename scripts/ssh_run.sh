#!/usr/bin/env bash
# =============================================================================
# ssh_run.sh plan|apply — genera lo stato desiderato e lo invia a mcp-reconcile
# sul server MCP tramite SSH. Il risultato viene stampato e aggiunto al riepilogo
# del job GitHub.
#
# Variabili richieste: MCP_SSH_KEY, MCP_SSH_KNOWN_HOSTS, MCP_SERVER_HOST
# In modalità apply anche: SECRETS_JSON  (= ${{ toJSON(secrets) }})
# La modalità effettiva è decisa dal server in base alla chiave usata
# (chiave "plan" = sola lettura, chiave "apply" = modifiche).
# =============================================================================
set -euo pipefail
mode="${1:?uso: ssh_run.sh plan|apply}"
: "${MCP_SSH_KEY:?MCP_SSH_KEY mancante}"
: "${MCP_SSH_KNOWN_HOSTS:?MCP_SSH_KNOWN_HOSTS mancante}"
: "${MCP_SERVER_HOST:?MCP_SERVER_HOST mancante}"
PY="${PYTHON:-python3}"

umask 077
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
printf '%s\n' "${MCP_SSH_KEY}" | tr -d '\r' > "${work}/key"
printf '%s\n' "${MCP_SSH_KNOWN_HOSTS}" > "${work}/known_hosts"

set +e
"${PY}" scripts/build_state.py "${mode}" \
  | ssh -i "${work}/key" \
        -o IdentitiesOnly=yes -o BatchMode=yes \
        -o StrictHostKeyChecking=yes -o UserKnownHostsFile="${work}/known_hosts" \
        -o ConnectTimeout=15 -o ServerAliveInterval=30 \
        -T "mcp-deploy@${MCP_SERVER_HOST}" > "${work}/out.md"
rc=("${PIPESTATUS[@]}")
set -e

cat "${work}/out.md"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then cat "${work}/out.md" >> "${GITHUB_STEP_SUMMARY}"; fi

if [[ ${rc[0]} -ne 0 ]]; then echo "::error::configurazione non valida (vedi sopra)"; exit 1; fi
if [[ ${rc[1]} -ne 0 ]]; then echo "::error::mcp-reconcile ${mode} non riuscito (codice ${rc[1]})"; exit 1; fi
