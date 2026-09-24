# Server MCP interno per Wazuh e UniFi (UDM Pro) con Claude Code

Guida per installare su un server interno due server MCP, uno per **Wazuh** e uno per **UniFi Network (UDM Pro)**, e usarli da un client **Fedora** tramite **Claude Code**.

---

## Indice

1. [Architettura](#1-architettura)
2. [Segnaposto usati nella guida](#2-segnaposto-usati-nella-guida)
3. [Client Fedora: installare Claude Code](#3-client-fedora-installare-claude-code)
4. [Server MCP: preparazione di base](#4-server-mcp-preparazione-di-base)
5. [Accesso SSH senza password dal Fedora](#5-accesso-ssh-senza-password-dal-fedora)
6. [Wazuh](#6-wazuh)
7. [UniFi / UDM Pro](#7-unifi--udm-pro)
8. [Registrare i server in Claude Code](#8-registrare-i-server-in-claude-code)
9. [Risoluzione dei problemi](#9-risoluzione-dei-problemi)
10. [Rimozione](#10-rimozione)
11. [Sicurezza: più server MCP e più utenti](#11-sicurezza-più-server-mcp-e-più-utenti)
12. [Automazione con GitHub Actions (GitOps)](#12-automazione-con-github-actions-gitops)

---

## 1. Architettura

```
┌──────────────────┐   SSH (stdio MCP)   ┌──────────────────────┐   HTTPS 55000/9200   ┌──────────────┐
│  Fedora          │ ──────────────────► │  Server MCP interno  │ ───────────────────► │  Wazuh       │
│  Claude Code     │                     │  utente: mcp         │                      │  (manager +  │
│                  │                     │  /opt/mcp-wazuh      │                      │   indexer)   │
│                  │                     │  /opt/mcp-unifi      │   HTTPS 443          ├──────────────┤
│                  │                     │                      │ ───────────────────► │  UDM Pro     │
└──────────────────┘                     └──────────────────────┘                      └──────────────┘
```

Scelte di progetto:

- **Trasporto stdio via SSH.** Claude Code lancia il server MCP sul server interno tramite SSH. Non servono porte aperte per l'MCP, l'autenticazione è quella delle chiavi SSH e le credenziali di Wazuh e UniFi restano **solo sul server**.
- **Account in sola lettura** su Wazuh (API e Indexer) e su UniFi, così Claude non può modificare nulla, qualunque cosa gli venga chiesto.
- **Claude Code (CLI)** sul client. Claude Desktop non ha una versione ufficiale per Linux, e i connettori di claude.ai web richiedono un server raggiungibile da Internet.

Progetti utilizzati:

| Componente | Progetto | Linguaggio |
|---|---|---|
| Wazuh | [gbrigandi/mcp-server-wazuh](https://github.com/gbrigandi/mcp-server-wazuh) | Rust (binario precompilato) |
| UniFi | [sirkirby/unifi-mcp](https://github.com/sirkirby/unifi-mcp) (pacchetto `unifi-network-mcp`) | Python 3.13+ |

---

## 2. Segnaposto usati nella guida

Sostituiscili con i tuoi valori:

| Segnaposto | Significato |
|---|---|
| `IP-SERVER-MCP` | IP del server interno che ospita i server MCP |
| `IP-WAZUH` | IP della macchina Wazuh (manager e indexer) |
| `IP-UDM-PRO` | IP del UDM Pro |
| `mcp_readonly` | Utente API di Wazuh in sola lettura |
| `mcp_indexer` | Utente dell'Indexer di Wazuh in sola lettura |
| `mcp_viewer` | Amministratore locale UniFi con ruolo *View Only* |

---

## 3. Client Fedora: installare Claude Code

Usa l'**installer nativo**: non richiede Node.js né permessi di root e si aggiorna da solo.

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

Apri un nuovo terminale e verifica:

```bash
which claude        # ~/.local/bin/claude
claude --version
claude              # primo avvio: login nel browser
```

> Se in passato avevi provato l'installazione con npm, vedi la [sezione 9](#9-risoluzione-dei-problemi).

---

## 4. Server MCP: preparazione di base

> Le sezioni 4–8 descrivono la configurazione **a utente singolo**. Se il server sarà usato da più persone o ospiterà più server MCP, segui la [sezione 11](#11-sicurezza-più-server-mcp-e-più-utenti), che separa utenti, credenziali e permessi.

Crea un utente di sistema dedicato e le cartelle:

```bash
sudo useradd -m -s /bin/bash mcp
sudo mkdir -p /opt/mcp-wazuh /opt/mcp-unifi
sudo chown mcp:mcp /opt/mcp-wazuh /opt/mcp-unifi
```

Imposta una password temporanea, che servirà solo per copiare la chiave SSH:

```bash
sudo passwd mcp
```

---

## 5. Accesso SSH senza password dal Fedora

Claude Code non può digitare password, quindi l'accesso deve funzionare con le chiavi.

Sul **Fedora**:

```bash
ssh-keygen -t ed25519            # solo se non hai già una chiave
ssh-copy-id mcp@IP-SERVER-MCP
ssh mcp@IP-SERVER-MCP            # primo accesso: rispondi "yes" alla fingerprint
```

Verifica che non venga chiesto nulla:

```bash
ssh -o BatchMode=yes -T mcp@IP-SERVER-MCP echo ok
```

Deve rispondere `ok`. A quel punto, se vuoi, puoi bloccare la password dell'utente, lasciando attivo il solo accesso con chiave:

```bash
sudo passwd -l mcp
```

---

## 6. Wazuh

### 6.1 Utente API di Wazuh in sola lettura

Nella dashboard di Wazuh vai su **Server management → Security → Users**:

1. Crea l'utente `mcp_readonly` con una password robusta.
2. Assegnagli il ruolo **`readonly`**.

### 6.2 Utente dell'Indexer in sola lettura

L'Indexer è basato su OpenSearch. Servono tre elementi: un **ruolo**, un **utente interno** e una **mappatura** tra i due.

#### Metodo A: dalla dashboard

Vai su **☰ → Indexer management → Security** (nelle versioni più vecchie: *OpenSearch Plugins → Security*).

1. **Roles → Create role** `mcp_alerts_readonly`
   - Cluster permissions: `cluster_composite_ops_ro`
   - Index: `wazuh-alerts-*`, `wazuh-states-vulnerabilities-*`
   - Index permissions: `read`
2. **Internal users → Create internal user** `mcp_indexer`, senza backend roles.
3. Nel ruolo `mcp_alerts_readonly` apri **Mapped users → Manage mapping** e aggiungi `mcp_indexer`.

#### Metodo B: da riga di comando (sulla macchina Wazuh)

```bash
read -s -p "Password admin indexer: " ADMIN_PW; echo
read -s -p "Nuova password per mcp_indexer: " MCP_PW; echo
IDX=https://localhost:9200

# Ruolo
curl -k -u "admin:$ADMIN_PW" -X PUT "$IDX/_plugins/_security/api/roles/mcp_alerts_readonly" \
  -H 'Content-Type: application/json' -d '{
  "cluster_permissions": ["cluster_composite_ops_ro"],
  "index_permissions": [{
    "index_patterns": ["wazuh-alerts-*", "wazuh-states-vulnerabilities-*"],
    "allowed_actions": ["read"]
  }]
}'

# Utente
curl -k -u "admin:$ADMIN_PW" -X PUT "$IDX/_plugins/_security/api/internalusers/mcp_indexer" \
  -H 'Content-Type: application/json' -d "{\"password\": \"$MCP_PW\"}"

# Mappatura
curl -k -u "admin:$ADMIN_PW" -X PUT "$IDX/_plugins/_security/api/rolesmapping/mcp_alerts_readonly" \
  -H 'Content-Type: application/json' -d '{"users": ["mcp_indexer"]}'
```

Verifica: il primo comando deve **riuscire**, gli altri due devono fallire con **403**.

```bash
curl -k -u "mcp_indexer:$MCP_PW" "$IDX/wazuh-alerts-*/_search?size=1&pretty"   # OK
curl -k -u "mcp_indexer:$MCP_PW" -X PUT "$IDX/test-mcp"                         # 403
curl -k -u "mcp_indexer:$MCP_PW" -X DELETE "$IDX/wazuh-alerts-*"                # 403

unset ADMIN_PW MCP_PW
```

> L'indice `wazuh-states-vulnerabilities-*` contiene i dati delle vulnerabilità da Wazuh 4.8 in poi. Nelle versioni precedenti puoi ometterlo.

### 6.3 Rete: Wazuh su una macchina separata

Sulla **macchina Wazuh**, verifica che i servizi ascoltino anche sulla rete e non solo in locale:

```bash
sudo ss -tlnp | grep -E '55000|9200'
```

Se l'Indexer ascolta solo su `127.0.0.1:9200`, imposta `network.host` in `/etc/wazuh-indexer/opensearch.yml` con l'IP della macchina, poi riavvia con `sudo systemctl restart wazuh-indexer`. L'IP deve corrispondere a quello presente nei certificati dell'Indexer.

Apri le porte **solo verso il server MCP**.

Con firewalld:

```bash
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="IP-SERVER-MCP" port port="55000" protocol="tcp" accept'
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="IP-SERVER-MCP" port port="9200" protocol="tcp" accept'
sudo firewall-cmd --reload
```

Con ufw:

```bash
sudo ufw allow from IP-SERVER-MCP to any port 55000 proto tcp
sudo ufw allow from IP-SERVER-MCP to any port 9200 proto tcp
```

Dal **server MCP**, verifica la connessione:

```bash
# API del manager: deve restituire un token JWT
curl -k -u mcp_readonly:PASSWORD -X POST "https://IP-WAZUH:55000/security/user/authenticate?raw=true"

# Indexer: deve restituire un alert
curl -k -u mcp_indexer:PASSWORD "https://IP-WAZUH:9200/wazuh-alerts-*/_search?size=1&pretty"
```

- *Connection timed out*: il problema è il firewall.
- *Connection refused*: il servizio ascolta solo in locale.

### 6.4 Installazione del server MCP di Wazuh

Sul **server MCP**:

```bash
sudo -iu mcp
cd /opt/mcp-wazuh

curl -LO https://github.com/gbrigandi/mcp-server-wazuh/releases/latest/download/mcp-server-wazuh-linux-amd64
chmod +x mcp-server-wazuh-linux-amd64
mv mcp-server-wazuh-linux-amd64 mcp-server-wazuh
```

> Se il download diretto non funziona, scarica il binario dalla pagina **Releases** del repository. Controlla l'architettura del server con `uname -m`.

### 6.5 Configurazione

`/opt/mcp-wazuh/wazuh.env`:

```bash
WAZUH_API_HOST=IP-WAZUH
WAZUH_API_PORT=55000
WAZUH_API_USERNAME=mcp_readonly
WAZUH_API_PASSWORD=la_password_api
WAZUH_INDEXER_HOST=IP-WAZUH
WAZUH_INDEXER_PORT=9200
WAZUH_INDEXER_USERNAME=mcp_indexer
WAZUH_INDEXER_PASSWORD=la_password_indexer
WAZUH_VERIFY_SSL=false
RUST_LOG=warn
```

`/opt/mcp-wazuh/run.sh`:

```bash
#!/bin/bash
set -a
source /opt/mcp-wazuh/wazuh.env
set +a
exec /opt/mcp-wazuh/mcp-server-wazuh --transport stdio
```

Permessi:

```bash
chmod 600 /opt/mcp-wazuh/wazuh.env
chmod 700 /opt/mcp-wazuh/run.sh
```

> **SSL:** `WAZUH_VERIFY_SSL=false` disattiva il controllo dei certificati. Per maggiore sicurezza, aggiungi il `root-ca.pem` di Wazuh alle CA di sistema del server MCP e imposta `true`.

---

## 7. UniFi / UDM Pro

### 7.1 Account dedicato sul UDM Pro

Nella console UniFi (**Admins & Users**) crea un **amministratore locale**:

- nome: `mcp_viewer`;
- ruolo **View Only** per Network;
- **non** usare un account Ubiquiti SSO cloud;
- **senza MFA/2FA**, che per questo account non è supportata.

### 7.2 Installazione

Sul **server MCP**:

```bash
sudo -iu mcp

curl -LsSf https://astral.sh/uv/install.sh | sh
source ~/.bashrc

uv tool install --python 3.13 unifi-network-mcp
which unifi-network-mcp     # es. /home/mcp/.local/bin/unifi-network-mcp
```

Per gli aggiornamenti futuri: `uv tool upgrade unifi-network-mcp`.

### 7.3 Configurazione

Salva la password in un file, senza lasciarla nella cronologia della shell:

```bash
read -s -p "Password mcp_viewer: " PW; echo
printf '%s' "$PW" > /opt/mcp-unifi/password
unset PW
```

`/opt/mcp-unifi/unifi.env`:

```bash
UNIFI_HOST=IP-UDM-PRO
UNIFI_USERNAME=mcp_viewer
UNIFI_PASSWORD_FILE=/opt/mcp-unifi/password
UNIFI_VERIFY_SSL=false
```

`/opt/mcp-unifi/run.sh`:

```bash
#!/bin/bash
set -a
source /opt/mcp-unifi/unifi.env
set +a
exec /home/mcp/.local/bin/unifi-network-mcp
```

Permessi:

```bash
chmod 600 /opt/mcp-unifi/password /opt/mcp-unifi/unifi.env
chmod 700 /opt/mcp-unifi/run.sh
```

Verifica che il UDM sia raggiungibile dal server MCP:

```bash
curl -k -I https://IP-UDM-PRO
```

> Il server non carica automaticamente i file `.env`: per questo le variabili vengono esportate da `run.sh`. `UNIFI_VERIFY_SSL=false` serve perché il UDM usa un certificato autofirmato.

---

## 8. Registrare i server in Claude Code

### 8.1 Test manuale (dal Fedora)

Prima di registrarli, prova i server a mano:

```bash
ssh -T mcp@IP-SERVER-MCP /opt/mcp-wazuh/run.sh
```

Il comando resta in attesa senza stampare nulla. Incolla questa riga e premi Invio:

```json
{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}
```

Deve rispondere con un JSON contenente `serverInfo`. Esci con **Ctrl+C**. Ripeti lo stesso test con `/opt/mcp-unifi/run.sh`.

### 8.2 Registrazione

```bash
claude mcp add --scope user wazuh -- ssh -o BatchMode=yes -o ConnectTimeout=10 -T mcp@IP-SERVER-MCP /opt/mcp-wazuh/run.sh

claude mcp add --scope user unifi -- ssh -o BatchMode=yes -o ConnectTimeout=10 -T mcp@IP-SERVER-MCP /opt/mcp-unifi/run.sh

claude mcp list
```

Le opzioni usate:

- `--scope user`: il server è disponibile in tutti i progetti;
- `BatchMode=yes`: SSH non fa domande, quindi fallisce subito invece di restare bloccato;
- `ConnectTimeout=10`: errore rapido se il server non è raggiungibile;
- `-T`: niente terminale, il canale stdio resta pulito.

### 8.3 Verifica in Claude Code

Avvia `claude` e digita `/mcp`: devi vedere `wazuh` e `unifi` connessi. Poi prova alcune richieste:

- "Mostrami gli ultimi alert critici di Wazuh"
- "Quali agenti Wazuh sono disconnessi?"
- "Mostrami i client connessi sulla VLAN ospiti"
- "Fai un audit delle regole firewall del UDM Pro"

---

## 9. Risoluzione dei problemi

### `npm error code EACCES` durante l'installazione di Claude Code

npm cerca di scrivere in `/usr/local/lib`. Non usare `sudo npm`: usa l'installer nativo ([sezione 3](#3-client-fedora-installare-claude-code)). Per eliminare un'eventuale installazione npm precedente:

```bash
npm uninstall -g @anthropic-ai/claude-code
npm config delete prefix
rm -rf ~/.npm-global
sed -i '/npm-global/d' ~/.bashrc
```

### `claude: File o directory non esistente` dopo il cambio di installazione

Bash ricorda ancora il vecchio percorso. Svuota la cache dei comandi:

```bash
hash -r
```

In alternativa, apri un nuovo terminale.

### `connection timed out after 30000ms`

Di solito SSH è in attesa di un input che Claude Code non può dare, oppure il server MCP non parte.

1. Esegui `ssh -o BatchMode=yes -T mcp@IP-SERVER-MCP echo ok` e interpreta il risultato:
   - `Host key verification failed`: collegati una volta a mano e accetta la fingerprint;
   - `Permission denied`: ripeti `ssh-copy-id`.
2. Esegui il test manuale della [sezione 8.1](#81-test-manuale-dal-fedora). Gli errori più comuni sono:
   - `Permission denied` / `No such file`: controlla percorsi e permessi (`ls -l /opt/mcp-*`);
   - `Exec format error`: il binario è per un'architettura sbagliata;
   - errori di connessione a Wazuh o UniFi: controlla host, porte, firewall e credenziali.
3. Per maggiori dettagli avvia Claude Code con `claude --debug`, oppure allunga l'attesa con `MCP_TIMEOUT=60000 claude`.

---

## 10. Rimozione

### Dal client (Claude Code)

```bash
claude mcp list
claude mcp remove wazuh --scope user
claude mcp remove unifi --scope user
```

Senza `--scope`, se il nome esiste in più scope, Claude Code chiede quale rimuovere. Riavvia Claude Code se era aperto.

### Dal server MCP (rimozione completa)

```bash
sudo rm -rf /opt/mcp-wazuh /opt/mcp-unifi
sudo userdel -r mcp
```

Poi elimina anche gli account creati:

- **Wazuh:** l'utente API `mcp_readonly`, l'utente dell'Indexer `mcp_indexer` e il ruolo `mcp_alerts_readonly`;
- **UniFi:** l'amministratore locale `mcp_viewer`;
- **Firewall della macchina Wazuh:** le regole per le porte 55000 e 9200.

---

## 11. Sicurezza: più server MCP e più utenti

Le sezioni 4–8 descrivono una configurazione **a utente singolo**: un solo account `mcp` possiede tutte le credenziali e chi ha la sua chiave SSH può usare tutti i server MCP e leggere tutte le credenziali. Con più persone e più server MCP servono separazione, privilegi minimi e tracciabilità.

### 11.1 Modello di sicurezza

```
Claude Code (alice) ── ssh alice@server wazuh ──► sshd
                                                  │  Match Group mcp-users:
                                                  │  solo chiave, niente shell, niente forwarding
                                                  ▼
                                   /usr/local/bin/mcp-gateway   (ForceCommand)
                                                  │  alice appartiene a mcp-wazuh-users?
                                                  │  registra ALLOW/DENY nel journal
                                                  ▼
                        sudo -u mcp-wazuh /opt/mcp-wazuh/run.sh
                                                  │  legge wazuh.env (visibile solo a mcp-wazuh)
                                                  ▼
                                      server MCP Wazuh (stdio)
```

| Livello | Protezione |
|---|---|
| Rete | SSH raggiungibile solo dalle reti dei client; porte dei backend aperte solo verso il server MCP |
| SSH | Solo chiavi, niente root, niente password, tentativi limitati, fail2ban |
| Utenti | Nessuna shell (`ForceCommand`), niente TTY né tunnel; chiavi in una cartella di root con scadenza opzionale |
| Separazione tra server | Ogni server MCP gira con il **proprio** utente di servizio: chi usa (o compromette) un server MCP non può leggere le credenziali di un altro |
| Autorizzazioni | Un gruppo per server MCP (`mcp-NOME-users`); una regola sudo consente di avviare **solo** il relativo `run.sh` |
| Credenziali | File `600` di proprietà dell'utente di servizio: le persone non possono leggerle |
| Backend | Account Wazuh e UniFi in sola lettura (sezioni 6 e 7) |
| Tracciabilità | Ogni accesso, consentito o negato, finisce nel journal (`mcp-gateway`, `sudo`, `sshd`) |

**Limite da conoscere.** Tutti gli utenti dello stesso server MCP usano lo stesso account sul backend (ad esempio `mcp_readonly` su Wazuh). Nei log di Wazuh o UniFi vedrai quindi sempre quell'account: per sapere *chi* ha fatto cosa, usa i log del gateway. Se ti servono permessi diversi per persona, crea istanze separate dello stesso server con account backend diversi, per esempio `wazuh` in sola lettura e `wazuh-admin` con più privilegi, ciascuna con il proprio gruppo.

### 11.2 Hardening del sistema

#### Aggiornamenti automatici di sicurezza

RHEL / Rocky / Alma (su Fedora recenti il pacchetto è la variante dnf5, `dnf5-plugin-automatic`):

```bash
sudo dnf install dnf-automatic
sudo sed -i 's/^apply_updates.*/apply_updates = yes/' /etc/dnf/automatic.conf
sudo systemctl enable --now dnf-automatic.timer
```

Debian / Ubuntu:

```bash
sudo apt install unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

#### SSH: configurazione globale

> ⚠️ **Prima di applicarla:** l'account amministratore deve già accedere con chiave SSH ed essere nel gruppo `ssh-admins`. Tieni **aperta una sessione** finché non hai verificato che una nuova connessione funziona.

```bash
sudo groupadd ssh-admins
sudo usermod -aG ssh-admins TUO_UTENTE_ADMIN
```

`/etc/ssh/sshd_config.d/00-hardening.conf`:

```
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
AllowGroups ssh-admins mcp-users
```

```bash
sudo sshd -t && sudo systemctl reload sshd     # su Debian/Ubuntu: reload ssh
sudo sshd -T | grep -Ei 'permitrootlogin|passwordauthentication|allowgroups'
```

In sshd vale il **primo** valore letto: il prefisso `00-` fa sì che queste impostazioni prevalgano sugli altri file in `sshd_config.d`. Verificalo sempre con `sshd -T`.

#### Firewall: SSH solo dalle reti dei client

firewalld (esempio con rete client `192.168.10.0/24`):

```bash
sudo firewall-cmd --permanent --remove-service=ssh
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.10.0/24" service name="ssh" accept'
sudo firewall-cmd --reload
```

ufw:

```bash
sudo ufw default deny incoming
sudo ufw allow from 192.168.10.0/24 to any port 22 proto tcp
sudo ufw enable
```

Per un livello in più, puoi limitare anche il traffico **in uscita**: il server MCP deve raggiungere solo Wazuh (55000, 9200), il UDM Pro (443), il DNS e i repository per gli aggiornamenti.

#### fail2ban

```bash
sudo dnf install fail2ban        # oppure: sudo apt install fail2ban
```

`/etc/fail2ban/jail.d/sshd.local`:

```ini
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
```

```bash
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

#### SELinux / AppArmor

Lascia **SELinux in modalità enforcing** (Fedora/RHEL: `getenforce` deve rispondere `Enforcing`) oppure AppArmor attivo (Debian/Ubuntu). Se sshd non legge le chiavi in `/etc/ssh/mcp_keys`, ripristina i contesti con `sudo restorecon -Rv /etc/ssh/mcp_keys`, invece di disattivare SELinux.

#### auditd: tracciare le modifiche ai file sensibili

`/etc/audit/rules.d/mcp.rules`:

```
-w /etc/ssh/mcp_keys/ -p wa -k mcp-keys
-w /etc/sudoers.d/ -p wa -k mcp-sudoers
-w /etc/ssh/sshd_config.d/ -p wa -k sshd-config
-w /usr/local/bin/mcp-gateway -p wa -k mcp-gateway
-w /opt/mcp-wazuh/ -p wa -k mcp-wazuh
-w /opt/mcp-unifi/ -p wa -k mcp-unifi
```

```bash
sudo augenrules --load
sudo ausearch -k mcp-keys -i        # esempio di consultazione
```

#### Monitorare il server MCP con Wazuh

Visto che hai già Wazuh, **installa l'agente Wazuh sul server MCP**: accessi SSH, uso di sudo, ban di fail2ban, eventi di auditd e l'integrità dei file (FIM su `/opt/mcp-*`, `/etc/ssh`, `/etc/sudoers.d`) arriveranno così alla tua console.

#### Altre buone pratiche

- Disattiva i servizi che non servono: `systemctl list-units --type=service --state=running`.
- Mantieni l'orario sincronizzato (chrony), essenziale per correlare i log.
- Fai un backup **cifrato** di `/opt/mcp-*` e `/etc/ssh/mcp_keys`.
- Ruota periodicamente le password degli account backend e le chiavi degli utenti (con `--expire`).

### 11.3 Installazione di `mcp-admin`

Lo script completo è nella [sezione 11.9](#119-lo-script-mcp-admin). Copialo sul server, poi:

```bash
sudo install -m 700 -o root -g root mcp-admin /usr/local/sbin/mcp-admin
sudo mcp-admin setup
```

`setup` esegue queste operazioni:

- crea il gruppo `mcp-users`;
- crea `/etc/ssh/mcp_keys/`, dove stanno le chiavi autorizzate: appartengono a root e gli utenti non possono modificarle;
- installa `/usr/local/bin/mcp-gateway`;
- scrive `/etc/ssh/sshd_config.d/10-mcp-users.conf` con il blocco `Match Group mcp-users`, lo verifica con `sshd -t` (se non è valido annulla la modifica) e ricarica sshd.

Per mostrare nelle istruzioni l'IP del server invece del nome host, avvia i comandi con `sudo MCP_SERVER_HOST=IP-SERVER-MCP mcp-admin ...`.

### 11.4 Creare i server MCP (e migrare da utente singolo)

```bash
sudo mcp-admin server-add wazuh
sudo mcp-admin server-add unifi
```

Per ogni server, `server-add` crea:

- l'utente di servizio `mcp-NOME` (senza shell);
- la cartella `/opt/mcp-NOME` con permessi `750`;
- il gruppo `mcp-NOME-users`;
- la regola `/etc/sudoers.d/mcp-NOME`, validata con `visudo`;
- un `run.sh` di esempio, se non ne esiste già uno.

Se la cartella esiste già, i file **non vengono sovrascritti**: ne viene solo cambiata la proprietà.

#### Wazuh

Se hai seguito la sezione 6, i file sono già in `/opt/mcp-wazuh`: `server-add wazuh` li assegna a `mcp-wazuh` e basta. Verifica:

```bash
sudo ls -l /opt/mcp-wazuh          # tutto di mcp-wazuh; wazuh.env con permessi 600
sudo -u mcp-wazuh /opt/mcp-wazuh/run.sh
```

Incolla la riga JSON di `initialize` (sezione 8.1): deve rispondere con `serverInfo`.

#### UniFi

Il pacchetto era installato nella home del vecchio utente `mcp`. Va reinstallato **dentro** `/opt/mcp-unifi`, così l'utente di servizio è autosufficiente:

```bash
# uv di sistema (una volta)
curl -LsSf https://astral.sh/uv/install.sh | sudo env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh

# Python e pacchetto dentro /opt/mcp-unifi, come utente di servizio
sudo -u mcp-unifi env HOME=/opt/mcp-unifi UV_PYTHON_INSTALL_DIR=/opt/mcp-unifi/python UV_CACHE_DIR=/opt/mcp-unifi/.cache \
  /usr/local/bin/uv venv --python 3.13 /opt/mcp-unifi/venv
sudo -u mcp-unifi env HOME=/opt/mcp-unifi UV_CACHE_DIR=/opt/mcp-unifi/.cache \
  /usr/local/bin/uv pip install --python /opt/mcp-unifi/venv/bin/python unifi-network-mcp
```

Nel file `/opt/mcp-unifi/run.sh`, l'ultima riga diventa:

```bash
exec /opt/mcp-unifi/venv/bin/unifi-network-mcp
```

Per gli aggiornamenti futuri, ripeti il secondo comando `uv pip install` aggiungendo `--upgrade`.

Se `unifi.env` e `password` erano già in `/opt/mcp-unifi`, rilancia `sudo mcp-admin server-add unifi` per riallinearne la proprietà. Poi prova con `sudo -u mcp-unifi /opt/mcp-unifi/run.sh`.

#### Eliminare il vecchio utente singolo

Quando i nuovi accessi funzionano:

```bash
sudo userdel -r mcp
```

Sui client, rimuovi le vecchie registrazioni (`claude mcp remove wazuh --scope user` e simili) e registra quelle nuove (sezione 11.6).

#### Aggiungere altri server MCP in futuro

```bash
sudo mcp-admin server-add NOME
```

Poi metti credenziali e binari in `/opt/mcp-NOME` (proprietà `mcp-NOME`, file segreti in `600`), completa `run.sh` e autorizza gli utenti con `user-grant`.

### 11.5 Gestione degli utenti

**Metodo consigliato: chiave generata dall'utente.** La chiave privata non lascia mai il suo PC. L'utente esegue sul proprio client `ssh-keygen -t ed25519 -f ~/.ssh/mcp_alice` e ti invia il file `.pub`:

```bash
sudo mcp-admin user-add alice --servers wazuh,unifi --pubkey /tmp/alice.pub --expire 20271231
```

**Alternativa: chiave generata sul server e mostrata a terminale.**

```bash
sudo mcp-admin user-add bob --servers wazuh
```

Lo script:

1. genera una chiave ed25519 in memoria (`/dev/shm`);
2. autorizza la chiave pubblica;
3. **stampa la chiave privata una sola volta** insieme ai comandi `claude mcp add` già pronti;
4. distrugge la chiave privata con `shred`.

Accortezze:

- trasmetti la chiave su un canale sicuro, non via email o chat in chiaro;
- ricorda che resta nello scrollback del terminale: chiudilo, oppure esegui `clear && printf '\033[3J'`;
- attenzione ai log di tmux o screen, se li usi.

La chiave non ha passphrase perché Claude Code usa SSH in modalità non interattiva. Se l'utente ne aggiunge una (`ssh-keygen -p -f ~/.ssh/mcp_bob`), dovrà caricarla in `ssh-agent` prima di avviare Claude Code.

Altri comandi:

```bash
sudo mcp-admin user-grant bob unifi          # aggiunge un server
sudo mcp-admin user-revoke bob unifi         # toglie un server e chiude le sue sessioni
sudo mcp-admin user-rotate-key bob           # nuova chiave (anche --pubkey / --expire)
sudo mcp-admin user-lock bob                 # sospende subito l'accesso
sudo mcp-admin user-unlock bob               # lo riattiva
sudo mcp-admin user-del bob                  # elimina l'utente e la sua chiave
sudo mcp-admin list                          # panoramica
```

Esempio di `list`:

```
SERVER MCP
  NOME                 RUN.SH    UTENTI AUTORIZZATI
  unifi                ok        alice
  wazuh                ok        alice,bob

UTENTI MCP
  UTENTE               CHIAVE      SCADENZA   SERVER
  alice                attiva      20271231   wazuh,unifi
  bob                  sospesa     -          wazuh
```

Le autorizzazioni aggiunte valgono dalla connessione successiva. `user-revoke`, `user-rotate-key`, `user-lock` e `user-del` chiudono subito **tutte** le sessioni attive dell'utente.

### 11.6 Lato client (per ogni utente)

1. Salva la chiave privata, per esempio in `~/.ssh/mcp_alice`, e proteggila con `chmod 600 ~/.ssh/mcp_alice`.
2. Aggiungi un alias in `~/.ssh/config`, così i comandi restano corti:

   ```
   Host mcp
       HostName IP-SERVER-MCP
       User alice
       IdentityFile ~/.ssh/mcp_alice
       IdentitiesOnly yes
       BatchMode yes
       ConnectTimeout 10
   ```

3. Esegui il primo collegamento, per accettare la fingerprint del server:

   ```bash
   ssh -o BatchMode=no -T mcp wazuh
   ```

   Se il comando resta in attesa senza errori, funziona: esci con Ctrl+C.

4. Registra i server in Claude Code:

   ```bash
   claude mcp add --scope user wazuh -- ssh -T mcp wazuh
   claude mcp add --scope user unifi -- ssh -T mcp unifi
   ```

L'ultimo argomento (`wazuh`, `unifi`) è il **nome del server MCP** richiesto al gateway: l'utente non indica mai percorsi o comandi.

### 11.7 Verifiche di sicurezza

Dal client di un utente, questi tentativi **devono fallire**:

```bash
ssh mcp                                  # "Accesso interattivo non consentito"
ssh mcp 'wazuh; id'                      # "Nome del server MCP non valido"
ssh mcp unifi                            # se non autorizzato: "Non sei autorizzato..."
ssh -N -L 8080:127.0.0.1:22 mcp          # il port forwarding viene rifiutato
```

Sul server:

```bash
# un utente non può leggere le credenziali
sudo -u alice cat /opt/mcp-wazuh/wazuh.env                # Permission denied

# un utente non può avviare comandi diversi da run.sh
sudo -u alice sudo -n -u mcp-wazuh /bin/bash              # rifiutato da sudo

# configurazione sshd effettiva per un utente MCP
sudo sshd -T -C user=alice,host=client,addr=192.168.10.20 \
  | grep -Ei 'forcecommand|disableforwarding|permittty|authorizedkeysfile'
```

### 11.8 Registri e audit

```bash
journalctl -t mcp-gateway --since today          # chi ha usato quale server MCP, e i tentativi negati
journalctl _COMM=sudo --since today              # esecuzioni di run.sh
journalctl -u sshd --since today                 # accessi SSH (su Debian/Ubuntu: -u ssh)
sudo ausearch -k mcp-keys -i                     # modifiche alle chiavi autorizzate
```

Esempio di voci del gateway:

```
mcp-gateway: ALLOW user=alice from=192.168.10.20 server=wazuh
mcp-gateway: DENY user=bob from=192.168.10.31 server=unifi reason=not-authorized
```

### 11.9 Lo script `mcp-admin`

Salvalo come `mcp-admin` e installalo come indicato nella [sezione 11.3](#113-installazione-di-mcp-admin). Questa versione non modifica proprietà e `run.sh` dei server gestiti dalla pipeline (sezione 12), riconoscibili dal file `.mcp-managed.json`.

```bash
#!/usr/bin/env bash
# =============================================================================
# mcp-admin — gestione di server MCP multipli e di utenti con accesso SSH limitato
#
# Convenzioni (per un server MCP chiamato NOME):
#   utente di servizio   mcp-NOME             possiede credenziali e processo
#   cartella             /opt/mcp-NOME        750, leggibile solo dal servizio
#   script di avvio      /opt/mcp-NOME/run.sh
#   gruppo autorizzati   mcp-NOME-users       chi può usare quel server MCP
#   regola sudo          /etc/sudoers.d/mcp-NOME
#
# Utenti (persone):
#   gruppo               mcp-users            sshd impone ForceCommand
#   chiave autorizzata   /etc/ssh/mcp_keys/UTENTE (di root, non modificabile)
#   nessuna shell, nessun forwarding: possono solo avviare i server MCP
#   a cui appartengono, tramite /usr/local/bin/mcp-gateway
#
# Uso: sudo mcp-admin help
# =============================================================================
set -euo pipefail

readonly MCP_BASE="/opt"
readonly USERS_GROUP="mcp-users"
readonly KEYS_DIR="/etc/ssh/mcp_keys"
readonly GATEWAY="/usr/local/bin/mcp-gateway"
readonly SSHD_DROPIN="/etc/ssh/sshd_config.d/10-mcp-users.conf"
readonly SUDOERS_DIR="/etc/sudoers.d"
SERVER_HOST="${MCP_SERVER_HOST:-$(hostname -f 2>/dev/null || hostname)}"

TMPDIR_KEY=""
cleanup() {
  if [[ -n "${TMPDIR_KEY}" && -d "${TMPDIR_KEY}" ]]; then
    find "${TMPDIR_KEY}" -type f -exec shred -u {} + 2>/dev/null || true
    rm -rf "${TMPDIR_KEY}"
  fi
}
trap cleanup EXIT

# ----------------------------------------------------------------------------- utilità
die()  { echo "ERRORE: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "ATTENZIONE: $*" >&2; }

need_root() { [[ ${EUID} -eq 0 ]] || die "esegui come root (sudo mcp-admin ...)"; }
need_setup() { [[ -x "${GATEWAY}" ]] || die "esegui prima: sudo mcp-admin setup"; }

valid_server_name() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{0,19}$ ]] \
    || die "nome server non valido '$1' (minuscole, cifre e '-', max 20 caratteri, inizia con una lettera)"
}

valid_user_name() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "nome utente non valido '$1'"
  [[ "$1" != mcp-* ]] || die "i nomi 'mcp-*' sono riservati agli utenti di servizio"
}

server_exists() { id "mcp-$1" &>/dev/null && [[ -d "${MCP_BASE}/mcp-$1" ]]; }

in_group() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$2"; }

require_mcp_user() {
  id "$1" &>/dev/null || die "l'utente '$1' non esiste"
  in_group "$1" "${USERS_GROUP}" || die "'$1' non è un utente MCP (non appartiene a ${USERS_GROUP})"
}

relabel() { command -v restorecon >/dev/null 2>&1 && restorecon -R "$@" 2>/dev/null || true; }

kill_sessions() {
  if pkill -u "$1" 2>/dev/null; then info "sessioni attive di '$1' terminate"; fi
}

split_servers() { tr ',' ' ' <<<"$1"; }

# ----------------------------------------------------------------------------- setup
install_gateway() {
  local tmp; tmp="$(mktemp)"
  cat >"${tmp}" <<'GATEWAY_EOF'
#!/usr/bin/env bash
# mcp-gateway — eseguito da sshd (ForceCommand) per i membri del gruppo mcp-users.
# Accetta solo il nome di un server MCP a cui l'utente è autorizzato e lo avvia
# come utente di servizio tramite sudo. Tutto viene registrato nel journal.
set -euo pipefail
req="${SSH_ORIGINAL_COMMAND:-}"
me="$(id -un)"
from="${SSH_CLIENT:-sconosciuto}"; from="${from%% *}"
log() { logger -t mcp-gateway -- "$*"; }

if [[ -z "${req}" ]]; then
  log "DENY user=${me} from=${from} reason=interactive"
  echo "Accesso interattivo non consentito. Uso: ssh ${me}@<server> <nome-mcp>" >&2
  exit 1
fi
if [[ ! "${req}" =~ ^[a-z][a-z0-9-]{0,19}$ ]]; then
  log "DENY user=${me} from=${from} reason=invalid-request"
  echo "Nome del server MCP non valido." >&2
  exit 1
fi
if ! id -nG "${me}" | tr ' ' '\n' | grep -qx "mcp-${req}-users"; then
  log "DENY user=${me} from=${from} server=${req} reason=not-authorized"
  echo "Non sei autorizzato al server MCP '${req}'." >&2
  exit 1
fi
log "ALLOW user=${me} from=${from} server=${req}"
exec /usr/bin/sudo -n -u "mcp-${req}" "/opt/mcp-${req}/run.sh"
GATEWAY_EOF
  install -m 755 -o root -g root "${tmp}" "${GATEWAY}"
  rm -f "${tmp}"
  info "gateway installato: ${GATEWAY}"
}

install_sshd_dropin() {
  local backup=""
  [[ -f "${SSHD_DROPIN}" ]] && { backup="$(mktemp)"; cp -p "${SSHD_DROPIN}" "${backup}"; }
  install -d -m 755 "$(dirname "${SSHD_DROPIN}")"
  cat >"${SSHD_DROPIN}" <<EOF
# Gestito da mcp-admin — utenti MCP: solo chiave, nessuna shell, nessun forwarding
Match Group ${USERS_GROUP}
    AuthorizedKeysFile ${KEYS_DIR}/%u
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    ForceCommand ${GATEWAY}
    PermitTTY no
    DisableForwarding yes
    PermitUserRC no
    ClientAliveInterval 60
    ClientAliveCountMax 3
# Chiude il blocco Match: le righe successive tornano globali
Match all
EOF
  chmod 644 "${SSHD_DROPIN}"
  if ! sshd -t; then
    if [[ -n "${backup}" ]]; then mv -f "${backup}" "${SSHD_DROPIN}"; else rm -f "${SSHD_DROPIN}"; fi
    die "configurazione sshd non valida: modifica annullata"
  fi
  [[ -n "${backup}" ]] && rm -f "${backup}"
  if grep -Eqs '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then :; else
    warn "/etc/ssh/sshd_config non include sshd_config.d/*.conf: aggiungi 'Include /etc/ssh/sshd_config.d/*.conf'"
  fi
  systemctl reload sshd 2>/dev/null || systemctl reload ssh
  info "configurazione sshd applicata: ${SSHD_DROPIN}"
}

cmd_setup() {
  need_root
  command -v sshd >/dev/null 2>&1 || die "sshd non trovato: installa openssh-server"
  command -v sudo >/dev/null 2>&1 || die "sudo non trovato: installalo prima di continuare"
  [[ -d "${SUDOERS_DIR}" ]] || die "${SUDOERS_DIR} non esiste"
  grep -Eqs '^[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers \
    || warn "/etc/sudoers non include /etc/sudoers.d: aggiungi '@includedir /etc/sudoers.d' con visudo"
  getent group "${USERS_GROUP}" >/dev/null || { groupadd "${USERS_GROUP}"; info "creato gruppo ${USERS_GROUP}"; }
  install -d -m 755 -o root -g root "${KEYS_DIR}"
  install_gateway
  install_sshd_dropin
  relabel "${KEYS_DIR}" "${GATEWAY}" "${SSHD_DROPIN}"
  info "setup completato"
}

# ----------------------------------------------------------------------------- server MCP
cmd_server_add() {
  need_root; need_setup
  local name="${1:-}"; [[ -n "${name}" ]] || die "uso: mcp-admin server-add NOME"
  valid_server_name "${name}"
  local svc="mcp-${name}" grp="mcp-${name}-users" dir="${MCP_BASE}/mcp-${name}"

  getent group "${grp}" >/dev/null || groupadd "${grp}"
  if ! id "${svc}" &>/dev/null; then
    useradd --system --no-create-home --home-dir "${dir}" \
            --shell /usr/sbin/nologin --comment "Servizio MCP ${name}" "${svc}"
  fi
  install -d -m 750 -o "${svc}" -g "${svc}" "${dir}"
  local managed=0
  [[ -f "${dir}/.mcp-managed.json" ]] && managed=1
  # i server gestiti da mcp-reconcile hanno codice e run.sh di root: non vanno toccati
  [[ ${managed} -eq 1 ]] || chown -R "${svc}:${svc}" "${dir}"

  if [[ ${managed} -eq 0 && ! -e "${dir}/run.sh" ]]; then
    cat >"${dir}/run.sh" <<EOF
#!/bin/bash
# Script di avvio del server MCP '${name}': sostituisci le ultime due righe
# con il comando reale (vedi la guida). Le variabili di ${name}.env vengono esportate.
set -a
[ -f ${dir}/${name}.env ] && source ${dir}/${name}.env
set +a
echo "Server MCP '${name}' non ancora configurato: modifica ${dir}/run.sh" >&2
exit 1
EOF
    chown "${svc}:${svc}" "${dir}/run.sh"
    info "creato modello ${dir}/run.sh (da completare)"
  fi
  [[ ${managed} -eq 1 ]] || chmod 700 "${dir}/run.sh"

  local tmp; tmp="$(mktemp)"
  cat >"${tmp}" <<EOF
# Gestito da mcp-admin: i membri di ${grp} possono avviare solo il server MCP '${name}'
Defaults:%${grp} !requiretty, !use_pty
%${grp} ALL=(${svc}) NOPASSWD: ${dir}/run.sh
EOF
  if ! visudo -cf "${tmp}" >/dev/null; then rm -f "${tmp}"; die "regola sudoers non valida"; fi
  install -m 440 -o root -g root "${tmp}" "${SUDOERS_DIR}/${svc}"
  rm -f "${tmp}"
  relabel "${dir}"
  info "server MCP '${name}' pronto (utente ${svc}, gruppo ${grp})"
  info "prova: sudo -u ${svc} ${dir}/run.sh"
}

cmd_server_del() {
  need_root
  local name="${1:-}"; [[ -n "${name}" ]] || die "uso: mcp-admin server-del NOME"
  valid_server_name "${name}"
  server_exists "${name}" || die "server MCP '${name}' inesistente"
  local svc="mcp-${name}" grp="mcp-${name}-users"
  rm -f "${SUDOERS_DIR}/${svc}"
  pkill -u "${svc}" 2>/dev/null || true
  groupdel "${grp}" 2>/dev/null || true
  userdel "${svc}"
  info "server MCP '${name}' disabilitato: regola sudo, gruppo e utente di servizio rimossi"
  warn "la cartella ${MCP_BASE}/mcp-${name} (con le credenziali) NON è stata cancellata"
}

# ----------------------------------------------------------------------------- chiavi
# write_key UTENTE FILE_CHIAVE_PUBBLICA|"" SCADENZA|""
write_key() {
  local user="$1" pubkey="$2" expire="$3" keyline opts="restrict"
  [[ -n "${expire}" ]] && opts+=",expiry-time=\"${expire}\""

  if [[ -n "${pubkey}" ]]; then
    [[ -r "${pubkey}" ]] || die "file non leggibile: ${pubkey}"
    keyline="$(grep -Em1 '^(ssh-|ecdsa-|sk-)' "${pubkey}" || true)"
    [[ -n "${keyline}" ]] || die "nessuna chiave pubblica valida in ${pubkey}"
    ssh-keygen -lf /dev/stdin <<<"${keyline}" >/dev/null 2>&1 || die "chiave pubblica non valida"
  else
    TMPDIR_KEY="$(mktemp -d -p /dev/shm 2>/dev/null || mktemp -d)"
    ssh-keygen -q -t ed25519 -N "" -C "${user}@mcp-$(hostname -s)" -f "${TMPDIR_KEY}/key"
    keyline="$(cat "${TMPDIR_KEY}/key.pub")"
  fi

  printf '%s %s\n' "${opts}" "${keyline}" >"${KEYS_DIR}/${user}.new"
  chown root:root "${KEYS_DIR}/${user}.new"
  chmod 644 "${KEYS_DIR}/${user}.new"
  mv -f "${KEYS_DIR}/${user}.new" "${KEYS_DIR}/${user}"
  rm -f "${KEYS_DIR}/${user}.disabled"
  relabel "${KEYS_DIR}/${user}"
  info "chiave autorizzata: $(ssh-keygen -lf /dev/stdin <<<"${keyline}" | awk '{print $2}')"
}

print_client_instructions() {
  local user="$1" servers="$2" keypath="~/.ssh/mcp_${user}"
  echo
  if [[ -n "${TMPDIR_KEY}" ]]; then
    echo "=================== CHIAVE PRIVATA DI ${user} (mostrata UNA SOLA VOLTA) ==================="
    cat "${TMPDIR_KEY}/key"
    echo "=========================================================================================="
    echo
    echo "La chiave privata NON resta sul server. Trasmettila all'utente su un canale sicuro."
    echo
    echo "Sul client di ${user}:"
    echo "  1. Salva il blocco sopra (incluse le righe BEGIN/END) in ${keypath}"
    echo "  2. chmod 600 ${keypath}"
    echo "  3. Registra i server MCP in Claude Code:"
  else
    keypath="<percorso-chiave-privata>"
    echo "Sul client di ${user} registra i server MCP in Claude Code:"
  fi
  local s
  for s in $(split_servers "${servers}"); do
    echo "     claude mcp add --scope user ${s} -- ssh -i ${keypath} -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -T ${user}@${SERVER_HOST} ${s}"
  done
  echo
  echo "Primo collegamento (accetta la fingerprint del server): ssh -i ${keypath} -T ${user}@${SERVER_HOST} ${s:-NOME}"
  echo "La risposta 'Server MCP non ancora configurato' o l'attesa silenziosa indicano che l'accesso funziona."
}

parse_key_opts() {
  # imposta OPT_PUBKEY, OPT_EXPIRE, OPT_SERVERS da "$@"
  OPT_PUBKEY=""; OPT_EXPIRE=""; OPT_SERVERS=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --servers) [[ $# -ge 2 ]] || die "--servers richiede un valore"; OPT_SERVERS="$2"; shift 2 ;;
      --pubkey)  [[ $# -ge 2 ]] || die "--pubkey richiede un file";   OPT_PUBKEY="$2";  shift 2 ;;
      --expire)  [[ $# -ge 2 ]] || die "--expire richiede AAAAMMGG";  OPT_EXPIRE="$2";  shift 2 ;;
      *) die "opzione sconosciuta: $1" ;;
    esac
  done
  if [[ -n "${OPT_EXPIRE}" ]]; then
    [[ "${OPT_EXPIRE}" =~ ^[0-9]{8}$ ]] || die "--expire deve essere nel formato AAAAMMGG"
    date -d "${OPT_EXPIRE}" >/dev/null 2>&1 || die "data di scadenza non valida: ${OPT_EXPIRE}"
  fi
}

# ----------------------------------------------------------------------------- utenti
cmd_user_add() {
  need_root; need_setup
  local user="${1:-}"; [[ -n "${user}" ]] || die "uso: mcp-admin user-add UTENTE --servers a,b [--pubkey FILE] [--expire AAAAMMGG]"
  shift
  valid_user_name "${user}"
  parse_key_opts "$@"
  [[ -n "${OPT_SERVERS}" ]] || die "indica almeno un server con --servers (es. --servers wazuh,unifi)"
  id "${user}" &>/dev/null && die "l'utente '${user}' esiste già"
  local s
  for s in $(split_servers "${OPT_SERVERS}"); do
    valid_server_name "${s}"; server_exists "${s}" || die "server MCP '${s}' inesistente (crealo con server-add)"
  done

  useradd --create-home --shell /bin/bash --comment "Utente MCP" --groups "${USERS_GROUP}" "${user}"
  usermod -p '*' "${user}"          # nessuna password, ma account non bloccato per le chiavi
  chmod 700 "$(getent passwd "${user}" | cut -d: -f6)"
  for s in $(split_servers "${OPT_SERVERS}"); do gpasswd -a "${user}" "mcp-${s}-users" >/dev/null; done

  write_key "${user}" "${OPT_PUBKEY}" "${OPT_EXPIRE}"
  info "utente '${user}' creato con accesso a: ${OPT_SERVERS}"
  print_client_instructions "${user}" "${OPT_SERVERS}"
}

cmd_user_grant() {
  need_root
  local user="${1:-}" server="${2:-}"
  [[ -n "${user}" && -n "${server}" ]] || die "uso: mcp-admin user-grant UTENTE SERVER"
  require_mcp_user "${user}"; valid_server_name "${server}"
  server_exists "${server}" || die "server MCP '${server}' inesistente"
  gpasswd -a "${user}" "mcp-${server}-users" >/dev/null
  info "'${user}' ora può usare '${server}' (vale dalla prossima connessione)"
}

cmd_user_revoke() {
  need_root
  local user="${1:-}" server="${2:-}"
  [[ -n "${user}" && -n "${server}" ]] || die "uso: mcp-admin user-revoke UTENTE SERVER"
  require_mcp_user "${user}"; valid_server_name "${server}"
  gpasswd -d "${user}" "mcp-${server}-users" >/dev/null 2>&1 || warn "'${user}' non era autorizzato a '${server}'"
  kill_sessions "${user}"
  info "accesso di '${user}' a '${server}' revocato"
}

cmd_user_rotate_key() {
  need_root
  local user="${1:-}"; [[ -n "${user}" ]] || die "uso: mcp-admin user-rotate-key UTENTE [--pubkey FILE] [--expire AAAAMMGG]"
  shift
  require_mcp_user "${user}"
  parse_key_opts "$@"
  write_key "${user}" "${OPT_PUBKEY}" "${OPT_EXPIRE}"
  kill_sessions "${user}"
  local servers
  servers="$(id -nG "${user}" | tr ' ' '\n' | sed -n 's/^mcp-\(.*\)-users$/\1/p' | paste -sd, -)"
  print_client_instructions "${user}" "${servers}"
}

cmd_user_lock() {
  need_root
  local user="${1:-}"; [[ -n "${user}" ]] || die "uso: mcp-admin user-lock UTENTE"
  require_mcp_user "${user}"
  [[ -f "${KEYS_DIR}/${user}" ]] && mv -f "${KEYS_DIR}/${user}" "${KEYS_DIR}/${user}.disabled"
  kill_sessions "${user}"
  info "'${user}' sospeso (riattiva con: mcp-admin user-unlock ${user})"
}

cmd_user_unlock() {
  need_root
  local user="${1:-}"; [[ -n "${user}" ]] || die "uso: mcp-admin user-unlock UTENTE"
  require_mcp_user "${user}"
  [[ -f "${KEYS_DIR}/${user}.disabled" ]] || die "'${user}' non risulta sospeso"
  mv -f "${KEYS_DIR}/${user}.disabled" "${KEYS_DIR}/${user}"
  info "'${user}' riattivato"
}

cmd_user_del() {
  need_root
  local user="${1:-}"; [[ -n "${user}" ]] || die "uso: mcp-admin user-del UTENTE"
  require_mcp_user "${user}"
  kill_sessions "${user}"
  sleep 1
  userdel -r "${user}" 2>/dev/null || userdel "${user}"
  rm -f "${KEYS_DIR}/${user}" "${KEYS_DIR}/${user}.disabled"
  info "utente '${user}' eliminato"
}

# ----------------------------------------------------------------------------- elenco
cmd_list() {
  echo "SERVER MCP"
  printf '  %-20s %-9s %s\n' "NOME" "RUN.SH" "UTENTI AUTORIZZATI"
  local d name state members found=0
  for d in "${MCP_BASE}"/mcp-*/; do
    [[ -d "${d}" ]] || continue
    name="$(basename "${d}")"; name="${name#mcp-}"
    id "mcp-${name}" &>/dev/null || continue
    found=1
    if [[ -e "${d}run.sh" ]]; then
      if grep -qs 'non ancora configurato' "${d}run.sh"; then state="modello"; else state="ok"; fi
    else
      state="assente"
    fi
    members="$(getent group "mcp-${name}-users" | cut -d: -f4)"
    printf '  %-20s %-9s %s\n' "${name}" "${state}" "${members:--}"
  done
  [[ ${found} -eq 1 ]] || echo "  (nessuno)"

  echo
  echo "UTENTI MCP"
  printf '  %-20s %-11s %-10s %s\n' "UTENTE" "CHIAVE" "SCADENZA" "SERVER"
  local u key expire servers
  local users; users="$(getent group "${USERS_GROUP}" | cut -d: -f4 | tr ',' ' ')"
  [[ -n "${users// /}" ]] || { echo "  (nessuno)"; return 0; }
  for u in ${users}; do
    if   [[ -f "${KEYS_DIR}/${u}" ]];          then key="attiva"
    elif [[ -f "${KEYS_DIR}/${u}.disabled" ]]; then key="sospesa"
    else                                            key="mancante"; fi
    expire="$(grep -hos 'expiry-time="[0-9]*"' "${KEYS_DIR}/${u}" "${KEYS_DIR}/${u}.disabled" 2>/dev/null \
              | head -n1 | tr -dc '0-9' || true)"
    servers="$(id -nG "${u}" | tr ' ' '\n' | sed -n 's/^mcp-\(.*\)-users$/\1/p' | paste -sd, -)"
    if [[ -n "${expire}" && "${key}" == "attiva" && "${expire}" -lt "$(date +%Y%m%d)" ]]; then key="scaduta"; fi
    printf '  %-20s %-11s %-10s %s\n' "${u}" "${key}" "${expire:--}" "${servers:--}"
  done
}

# ----------------------------------------------------------------------------- aiuto
usage() {
  cat <<EOF
mcp-admin — gestione di server MCP e utenti con accesso SSH limitato

Configurazione iniziale (una volta):
  setup                                   gruppo mcp-users, gateway, regole sshd

Server MCP:
  server-add NOME                         crea utente di servizio, cartella, gruppo e regola sudo
  server-del NOME                         rimuove regola sudo, gruppo e utente (non la cartella)

Utenti:
  user-add UTENTE --servers a,b [--pubkey FILE] [--expire AAAAMMGG]
                                          crea l'utente; senza --pubkey genera una chiave
                                          ed25519 e la mostra una sola volta
  user-grant UTENTE SERVER                autorizza un server MCP
  user-revoke UTENTE SERVER               revoca un server MCP (chiude le sessioni)
  user-rotate-key UTENTE [--pubkey FILE] [--expire AAAAMMGG]
                                          sostituisce la chiave
  user-lock UTENTE / user-unlock UTENTE   sospende / riattiva l'accesso
  user-del UTENTE                         elimina l'utente

  list                                    mostra server, utenti, permessi e scadenze

Variabili:
  MCP_SERVER_HOST   nome o IP del server da mostrare nelle istruzioni (predefinito: hostname -f)
EOF
}

# ----------------------------------------------------------------------------- main
main() {
  local cmd="${1:-help}"; shift || true
  case "${cmd}" in
    setup)            cmd_setup "$@" ;;
    server-add)       cmd_server_add "$@" ;;
    server-del)       cmd_server_del "$@" ;;
    user-add)         cmd_user_add "$@" ;;
    user-grant)       cmd_user_grant "$@" ;;
    user-revoke)      cmd_user_revoke "$@" ;;
    user-rotate-key)  cmd_user_rotate_key "$@" ;;
    user-lock)        cmd_user_lock "$@" ;;
    user-unlock)      cmd_user_unlock "$@" ;;
    user-del)         cmd_user_del "$@" ;;
    list)             cmd_list ;;
    help|-h|--help)   usage ;;
    *)                usage; exit 1 ;;
  esac
}

main "$@"
```

---

## 12. Automazione con GitHub Actions (GitOps)

In questa sezione la gestione di server MCP e utenti passa da comandi manuali a **file YAML versionati su GitHub**. Ogni modifica segue lo stesso percorso: pull request, piano automatico, revisione, approvazione e applicazione. Le credenziali usate dai server MCP (API key, username, password) restano nei **secret di GitHub** e arrivano sul server solo dopo l'approvazione.

### 12.1 Come funziona

```
 PR su config/ o keys/                          merge su main
        │                                              │
        ▼                                              ▼
 ┌──────────────────────┐                   ┌──────────────────────┐
 │ mcp-plan.yml         │                   │ mcp-deploy.yml       │
 │ validazione YAML     │                   │ job "plan"           │
 │ piano (sola lettura) │                   │ piano nel riepilogo  │
 └──────────┬───────────┘                   └──────────┬───────────┘
            │ revisione CODEOWNERS                     │
            ▼                                          ▼
        merge ───────────────────────────►  ⏸  APPROVAZIONE (environment mcp-production)
                                                       │  solo ora il job riceve
                                                       │  chiave "apply" e credenziali
                                                       ▼
                                            ┌──────────────────────┐
                                            │ job "apply"          │
                                            │ ssh mcp-deploy@...   │──► mcp-reconcile apply
                                            └──────────────────────┘        │
                                                                            ▼
                                                                   mcp-admin (utenti, chiavi,
                                                                   sudo) + installazione e
                                                                   configurazione dei server
```

Principi:

- **Dichiarativo.** I file YAML descrivono lo stato voluto. `mcp-reconcile` confronta questo stato con il server ed esegue solo le differenze. Se un utente sparisce dal file, viene eliminato (deprovisioning).
- **Due chiavi SSH distinte.** La chiave *plan* può eseguire solo `mcp-reconcile plan`, che non modifica nulla. La chiave *apply* può eseguire solo `mcp-reconcile apply` e sta esclusivamente nell'environment protetto. Il vincolo è imposto dal server, con `command=` e `from=` nelle chiavi autorizzate, e non dalla pipeline.
- **Segreti dopo l'approvazione.** Il job che riceve i secret dell'environment si ferma finché non viene approvato. I valori non compaiono mai nel repository, nel piano o nei log.
- **Freni di sicurezza.** L'apply si blocca se eliminerebbe più utenti di `policy.max_user_deletions`. I binari scaricati devono corrispondere allo sha256 dichiarato. I pacchetti pip devono avere una versione fissa.
- **Drift.** Il piano notturno segnala le modifiche fatte a mano sul server. Il successivo apply le riallinea al file.

> Quando la pipeline è attiva, **non gestire utenti e server a mano** con `mcp-admin`: il deploy successivo riporterebbe tutto a quanto scritto nei file YAML. `mcp-admin` resta utile per consultare (`list`) e per le emergenze (sezione 12.8).

### 12.2 Requisiti e limiti

**Step di approvazione e piano GitHub.** L'approvazione nativa usa i *required reviewers* degli environment. Con i piani GitHub Free, Pro e Team, i revisori obbligatori sono disponibili solo per i repository pubblici. Per un repository **privato** (quello giusto per questo uso) serve **GitHub Enterprise**. Environment, secret di environment e restrizioni sui branch sono invece disponibili anche nei repository privati con Pro, Team ed Enterprise.

Se sei su Team o Pro con un repository privato:

- il job `apply` non si fermerà ad aspettare, ma riceverà comunque i secret solo da `main`, grazie alle *deployment branches*;
- l'approvazione diventa la **revisione obbligatoria della pull request** da parte dei CODEOWNERS, imposta dalle regole del branch `main` (disponibili sui piani a pagamento);
- per aggiungere un secondo passaggio manuale, togli il trigger `push` da `mcp-deploy.yml` e lascia solo `workflow_dispatch`: il deploy partirà solo quando una persona autorizzata preme **Run workflow**, dopo aver letto il piano della PR.

**Runner self-hosted.** Il server MCP è nella rete interna, quindi i runner ospitati da GitHub non lo raggiungono. Serve un runner nella tua rete (sezione 12.5).

**Accesso a Internet dal server MCP.** Per le installazioni servono GitHub (release dei binari e build di Python usate da `uv`) e PyPI. Se il server non ha accesso in uscita, usa `install.method: none` e installa a mano.

**Solo chiavi pubbliche.** Nella pipeline gli utenti forniscono sempre la propria chiave pubblica. La modalità "chiave generata dal server" di `mcp-admin` non è usata, perché la chiave privata finirebbe nei log.

### 12.3 Struttura del repository

```
mcp-infra/
├── .github/
│   ├── CODEOWNERS
│   └── workflows/
│       ├── mcp-plan.yml        # PR, notturno, manuale: validazione + piano
│       └── mcp-deploy.yml      # main: piano → approvazione → apply
├── config/
│   ├── servers.yaml            # server MCP, installazione, variabili, riferimenti ai secret
│   └── users.yaml              # utenti, server autorizzati, scadenze, sospensioni
├── keys/
│   ├── alice.pub               # una chiave pubblica per utente
│   └── bob.pub
├── scripts/
│   ├── build_state.py          # YAML → JSON (con o senza segreti)
│   └── ssh_run.sh              # invia lo stato al server via SSH
└── server/                     # da installare sul server MCP
    ├── mcp-admin
    ├── mcp-reconcile
    └── install-deploy.sh
```

Il repository modello completo è allegato come archivio. Il codice di tutti i file è anche nella [sezione 12.11](#1211-codice).

### 12.4 Preparazione del server MCP

**1. Prerequisiti.** Servono `python3`, `sudo` e, per i server con `install.method: pip`, `uv` in `/usr/local/bin`:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sudo env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh
```

**2. Genera le due chiavi della pipeline** su una postazione di amministrazione, non sul runner:

```bash
ssh-keygen -t ed25519 -N "" -C "mcp-plan"  -f mcp_plan
ssh-keygen -t ed25519 -N "" -C "mcp-apply" -f mcp_apply
```

**3. Installa** sul server MCP, copiando la cartella `server/` del repository e le due chiavi **pubbliche**:

```bash
cd server
sudo ./install-deploy.sh --plan-key ../mcp_plan.pub --apply-key ../mcp_apply.pub --from IP-RUNNER
```

Lo script esegue queste operazioni:

- installa `mcp-admin` e `mcp-reconcile` (ed esegue `mcp-admin setup` se non è mai stato fatto);
- crea l'utente `mcp-deploy`;
- scrive la regola sudo, che consente **solo** `mcp-reconcile plan` e `mcp-reconcile apply`;
- scrive le chiavi autorizzate in `/etc/ssh/mcp_deploy_keys`:

  ```
  restrict,from="IP-RUNNER",command="/usr/bin/sudo -n /usr/local/sbin/mcp-reconcile plan"  ssh-ed25519 ... mcp-plan
  restrict,from="IP-RUNNER",command="/usr/bin/sudo -n /usr/local/sbin/mcp-reconcile apply" ssh-ed25519 ... mcp-apply
  ```

- aggiunge il blocco sshd `Match User mcp-deploy`.

**4. Hardening.** Se usi `AllowGroups` (sezione 11.2), aggiungi `mcp-deploy`:

```
AllowGroups ssh-admins mcp-users mcp-deploy
```

Nel firewall del server MCP, consenti SSH anche dall'IP del runner.

**5. Verifica dal runner.** Uno stato vuoto deve produrre un errore di validazione: vuol dire che SSH, sudo e reconcile rispondono.

```bash
echo '{}' | ssh -i mcp_plan -T mcp-deploy@IP-SERVER-MCP
# ### ❌ Stato non valido
# versione dello stato non supportata
```

**6. Server già configurati a mano** (sezioni 6, 7 e 11). Dichiarali in `servers.yaml` con lo stesso nome. Al primo apply compare `presa in gestione`: `run.sh`, il file `.env` e i file dei segreti vengono rigenerati dal YAML, e il codice viene reinstallato secondo `install`. I vecchi file che non corrispondono più a nulla (es. `/opt/mcp-unifi/.cache`) si possono cancellare a mano.

### 12.5 Runner self-hosted

- Usa una **VM dedicata**: non il server MCP, non una postazione personale. Il runner riceve la chiave apply e le credenziali, quindi va protetto come il server MCP (hardening della sezione 11.2, aggiornamenti, agente Wazuh).
- Idealmente **due runner**: uno con etichetta `mcp-plan` e uno con etichetta `mcp-apply`, quest'ultimo usato solo dal job di deploy. Con un solo runner assegnagli entrambe le etichette.
- Pacchetti necessari: `git`, `python3`, `python3-venv` (Debian/Ubuntu), `openssh-client`.
- Registrazione da **Settings → Actions → Runners → New self-hosted runner**. Segui i comandi mostrati, indicando le etichette ed eseguendolo come servizio con un utente non privilegiato:

  ```bash
  ./config.sh --url https://github.com/TUA-ORG/mcp-infra --token <TOKEN> \
              --labels mcp-apply --name mcp-runner-apply --unattended
  sudo ./svc.sh install runner      # "runner" = utente locale senza privilegi
  sudo ./svc.sh start
  ```

- Valuta i runner **effimeri** (`--ephemeral`): eseguono un solo job e poi si deregistrano. Vanno però ricreati automaticamente.
- Usa il runner solo con questo **repository privato**. I workflow sono configurati per non girare sulle PR provenienti da fork.

### 12.6 Configurazione del repository GitHub

**Environment `mcp-production`** (Settings → Environments → New environment):

- **Required reviewers**: le persone o il team che approvano. Attiva *Prevent self-review*. Su Team/Pro con repository privato vedi la sezione 12.2.
- **Deployment branches and tags**: *Selected branches* → solo `main`.

**Secret e variabili:**

| Nome | Tipo | Dove | Contenuto |
|---|---|---|---|
| `MCP_PLAN_SSH_KEY` | secret | repository | chiave privata `mcp_plan` (può solo leggere) |
| `MCP_APPLY_SSH_KEY` | secret | environment `mcp-production` | chiave privata `mcp_apply` |
| `WAZUH_API_USERNAME`, `WAZUH_API_PASSWORD` | secret | environment `mcp-production` | utente API Wazuh in sola lettura |
| `WAZUH_INDEXER_USERNAME`, `WAZUH_INDEXER_PASSWORD` | secret | environment `mcp-production` | utente dell'Indexer in sola lettura |
| `UNIFI_USERNAME`, `UNIFI_PASSWORD` | secret | environment `mcp-production` | amministratore locale UniFi *View Only* |
| `MCP_SERVER_HOST` | variabile | repository | IP o nome del server MCP |
| `MCP_SSH_KNOWN_HOSTS` | variabile | repository | riga known_hosts del server (stampata da `install-deploy.sh`) |

Con la CLI `gh`, dalla cartella con le chiavi:

```bash
gh secret set MCP_PLAN_SSH_KEY < mcp_plan
gh secret set MCP_APPLY_SSH_KEY --env mcp-production < mcp_apply
gh secret set WAZUH_API_USERNAME --env mcp-production        # chiede il valore senza mostrarlo
gh secret set WAZUH_API_PASSWORD --env mcp-production
gh secret set WAZUH_INDEXER_USERNAME --env mcp-production
gh secret set WAZUH_INDEXER_PASSWORD --env mcp-production
gh secret set UNIFI_USERNAME --env mcp-production
gh secret set UNIFI_PASSWORD --env mcp-production

gh variable set MCP_SERVER_HOST --body "IP-SERVER-MCP"
gh variable set MCP_SSH_KNOWN_HOSTS --body "IP-SERVER-MCP ssh-ed25519 AAAA..."

shred -u mcp_plan mcp_apply       # le chiavi private ora esistono solo su GitHub
```

Verifica la fingerprint prima di salvarla: dal runner esegui `ssh-keyscan -t ed25519 IP-SERVER-MCP`, poi confronta con `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` eseguito **sul server**. Il nome nella riga known_hosts deve coincidere con `MCP_SERVER_HOST`.

**Regole del branch `main`** (Settings → Rules → Rulesets, oppure Branch protection):

- pull request obbligatoria, con almeno 1 approvazione e **revisione dei Code Owners** (file `.github/CODEOWNERS`);
- *Dismiss stale approvals* quando arrivano nuovi commit;
- status check obbligatorio: `plan` (del workflow `MCP · validazione e piano`);
- niente force push né cancellazione, e le regole valgono anche per gli amministratori.

**Impostazioni di Actions** (Settings → Actions → General):

- *Workflow permissions*: **Read repository contents**;
- consenti solo azioni di GitHub e verificate;
- per le PR da fork, richiedi l'approvazione prima di eseguire i workflow.

Per un livello in più, fissa `actions/checkout` a uno SHA di commit invece del tag `@v4`.

### 12.7 I file di configurazione

**`config/servers.yaml`**: ogni server MCP ha questi campi.

| Campo | Significato |
|---|---|
| `state` | `present` (predefinito) o `absent` per dismetterlo: rimuove utente di servizio, gruppo e regola sudo, ma conserva la cartella |
| `install.method: binary` | scarica `url` (solo https), verifica `sha256` (obbligatorio) e installa in `{dir}/bin/<name>` |
| `install.method: pip` | crea `{dir}/venv` con Python `python` tramite `uv` e installa `package` (versione obbligatoria, `nome==x.y.z`) |
| `install.method: none` | nessuna installazione automatica |
| `command` | comando del server MCP; `{dir}` diventa `/opt/mcp-NOME` |
| `env` | variabili del file `/opt/mcp-NOME/NOME.env`; `{ secret: NOME }` prende il valore dal secret GitHub |
| `files` | file creati in `{dir}` (es. il file password di UniFi), con valore letterale o `{ secret: NOME }` |

Permessi sul server: il codice (`bin/`, `venv/`, `python/`) e `run.sh` sono di **root** e leggibili dall'utente di servizio, che quindi non può modificare il proprio codice. I file `.env` e dei segreti sono `640 root:mcp-NOME`.

**`config/users.yaml`**:

| Campo | Significato |
|---|---|
| `servers` | server MCP autorizzati (almeno uno) |
| `expire` | facoltativo, `AAAA-MM-GG`: dopo questa data la chiave smette di funzionare |
| `enabled` | `false` sospende l'utente senza eliminarlo |
| `key_file` | facoltativo, predefinito `keys/NOME.pub` |

Il file `keys/NOME.pub` contiene una sola riga: la chiave pubblica senza opzioni davanti.

### 12.8 Operazioni quotidiane

Ogni operazione è una pull request. Il piano compare nel riepilogo del job.

| Operazione | Cosa cambiare |
|---|---|
| Nuovo utente | aggiungi `keys/NOME.pub` e la voce in `users.yaml` |
| Dare o togliere un server | modifica `servers:` dell'utente |
| Sospendere | `enabled: false` |
| Deprovisioning | rimuovi la voce da `users.yaml` e il file `.pub` |
| Nuova chiave (PC cambiato o perso) | sostituisci `keys/NOME.pub` |
| Scadenza | aggiungi o modifica `expire` |
| Nuovo server MCP | aggiungi il blocco in `servers.yaml` e i relativi secret nell'environment, poi autorizza gli utenti |
| Aggiornare un server MCP | cambia `url` e `sha256`, oppure la versione in `package` |
| Ruotare una credenziale | aggiorna il secret su GitHub, poi **Actions → MCP · deploy → Run workflow** (nessuna PR necessaria) |
| Dismettere un server | `state: absent`, dopo averlo tolto a tutti gli utenti |
| Eliminare molti utenti insieme | alza temporaneamente `policy.max_user_deletions` nella stessa PR |

**Emergenze** (chiave compromessa, dipendente uscito all'improvviso). Blocca subito dal server:

```bash
sudo mcp-admin user-lock NOME
```

Poi apri **subito** la PR (`enabled: false` o rimozione dell'utente). Altrimenti il deploy successivo, oppure un apply manuale, riattiverebbe l'utente.

### 12.9 Cosa vede chi approva

Il riepilogo del job `plan` mostra le modifiche prima dell'approvazione:

```
### Piano MCP — 5 modifiche

- 🟡 server `wazuh`: installazione binario mcp-server-wazuh (sha256 3f9a1c0b2e4d…)
- 🟡 utente `alice`: scadenza 20280630
- 🟢 utente `carla`: creazione con accesso a unifi
- 🟡 utente `bob`: sospeso
- 🔴 utente `dario`: eliminato

> I valori segreti non sono disponibili in fase di piano: vengono confrontati durante l'apply.
```

Il job `apply` riporta l'esito di ogni operazione, segnalando per nome, e mai per valore, le variabili segrete cambiate. Al primo errore l'applicazione si interrompe e le operazioni successive non vengono eseguite.

### 12.10 Riepilogo della sicurezza della pipeline

| Rischio | Contromisura |
|---|---|
| Modifica non autorizzata della configurazione | PR obbligatoria, revisione CODEOWNERS, approvazione dell'environment |
| PR che modifica il workflow per fare apply | la chiave apply esiste solo nell'environment, limitato a `main`; la chiave plan può solo leggere, per vincolo del server |
| Furto della chiave della pipeline | `from=` limita l'uso all'IP del runner; `command=` limita il comando; nessuna shell, nessun forwarding |
| Esposizione dei segreti | secret GitHub, disponibili solo dopo l'approvazione e mascherati nei log; inviati via stdin SSH, mai su disco sul runner né nella riga di comando; sul server in file `640` |
| Binari manomessi | sha256 obbligatorio e versioni pip fissate |
| Errore di massa | `max_user_deletions` |
| Man-in-the-middle SSH | `StrictHostKeyChecking=yes` con fingerprint verificata in `MCP_SSH_KNOWN_HOSTS` |
| Esecuzioni concorrenti | `concurrency` nel workflow e lock sul server |
| Tracciabilità | cronologia Git e approvazioni su GitHub; `journalctl -t mcp-reconcile`, `-t mcp-gateway` e auditd sul server |

Una nota sul passaggio dei secret: il workflow passa allo script tutti i secret disponibili (`toJSON(secrets)`), perché i nomi da usare sono definiti nei file YAML. Lo script usa solo quelli richiesti e non li stampa mai. Tieni comunque nell'environment `mcp-production` solo i secret di questa pipeline.

### 12.11 Codice

#### 12.11.1 mcp-reconcile (server)

`server/mcp-reconcile`

```python
#!/usr/bin/env python3
"""
mcp-reconcile — allinea server MCP e utenti allo stato desiderato ricevuto su stdin (JSON).

    mcp-reconcile plan  < stato.json    mostra le modifiche, non modifica nulla
    mcp-reconcile apply < stato.json    applica le modifiche (lo stato deve contenere i segreti)

Viene eseguito come root, di norma tramite la chiave SSH della pipeline (utente mcp-deploy),
e usa mcp-admin per tutte le operazioni su utenti, gruppi, chiavi e regole sudo.
Solo libreria standard di Python 3.8+.
"""
import fcntl
import grp
import hashlib
import json
import os
import pwd
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.request

MCP_ADMIN = "/usr/local/sbin/mcp-admin"
GATEWAY = "/usr/local/bin/mcp-gateway"
BASE = "/opt"
KEYS_DIR = "/etc/ssh/mcp_keys"
USERS_GROUP = "mcp-users"
UV = "/usr/local/bin/uv"
LOCK_FILE = "/run/mcp-reconcile.lock"
STATE_FILE = ".mcp-managed.json"
MAX_INPUT = 1_000_000
MAX_DOWNLOAD = 300 * 1024 * 1024

RE_SERVER = re.compile(r"[a-z][a-z0-9-]{0,19}")
RE_USER = re.compile(r"[a-z_][a-z0-9_-]{0,31}")
RE_ENV = re.compile(r"[A-Z_][A-Z0-9_]{0,63}")
RE_FILE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
RE_SHA256 = re.compile(r"[0-9a-f]{64}")
RE_EXPIRE = re.compile(r"[0-9]{8}")
RE_PKG = re.compile(r"[A-Za-z0-9][A-Za-z0-9._\-\[\],<>=!~ ]{0,120}")
RE_PY = re.compile(r"3\.[0-9]{1,2}")
RE_KEY = re.compile(
    r"(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)|"
    r"sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) "
    r"([A-Za-z0-9+/]{16,}={0,3})(?: [\x21-\x7e ]{0,100})?"
)
RESERVED_FILES = {"run.sh", STATE_FILE, "bin", "venv", "python"}


class Fail(Exception):
    pass


# ----------------------------------------------------------------------------- validazione
def _need(cond, msg):
    if not cond:
        raise Fail(msg)


def validate(state, mode):
    _need(isinstance(state, dict), "lo stato deve essere un oggetto JSON")
    _need(state.get("version") == 1, "versione dello stato non supportata")
    policy = state.get("policy") or {}
    maxdel = policy.get("max_user_deletions", 3)
    _need(isinstance(maxdel, int) and maxdel >= 0, "policy.max_user_deletions non valido")

    servers = state.get("servers") or {}
    users = state.get("users") or {}
    _need(isinstance(servers, dict) and isinstance(users, dict), "servers e users devono essere oggetti")

    for name, s in servers.items():
        _need(RE_SERVER.fullmatch(name), f"nome server non valido: {name!r}")
        _need(s.get("state", "present") in ("present", "absent"), f"{name}: state non valido")
        if s.get("state") == "absent":
            continue
        inst = s.get("install") or {"method": "none"}
        method = inst.get("method")
        if method == "binary":
            _need(str(inst.get("url", "")).startswith("https://"), f"{name}: install.url deve essere https")
            _need(RE_SHA256.fullmatch(str(inst.get("sha256", ""))), f"{name}: install.sha256 mancante o non valido")
            _need(RE_FILE.fullmatch(str(inst.get("name", ""))), f"{name}: install.name non valido")
        elif method == "pip":
            _need(RE_PKG.fullmatch(str(inst.get("package", ""))), f"{name}: install.package non valido")
            _need(RE_PY.fullmatch(str(inst.get("python", "3.13"))), f"{name}: install.python non valido")
        else:
            _need(method == "none", f"{name}: install.method deve essere binary, pip o none")
        cmd = s.get("command")
        _need(isinstance(cmd, list) and cmd and all(isinstance(c, str) and "\n" not in c for c in cmd),
              f"{name}: command deve essere una lista di stringhe")
        _need(cmd[0].replace("{dir}", sdir(name)).startswith("/"), f"{name}: command[0] deve essere un percorso assoluto")
        for key, val in (s.get("env") or {}).items():
            _need(RE_ENV.fullmatch(key), f"{name}: variabile non valida {key!r}")
            _check_value(name, key, val, mode)
        for fname, val in (s.get("files") or {}).items():
            _need(RE_FILE.fullmatch(fname) and fname not in RESERVED_FILES and not fname.endswith(".env"),
                  f"{name}: nome file non valido {fname!r}")
            _check_value(name, fname, val, mode)

    present = {n for n, s in servers.items() if s.get("state", "present") == "present"}
    for u, spec in users.items():
        _need(RE_USER.fullmatch(u) and not u.startswith("mcp-"), f"nome utente non valido: {u!r}")
        _need(isinstance(spec.get("enabled", True), bool), f"{u}: enabled deve essere true/false")
        srv = spec.get("servers")
        _need(isinstance(srv, list) and srv, f"{u}: servers deve contenere almeno un server")
        for x in srv:
            _need(x in present, f"{u}: server {x!r} non dichiarato o dismesso")
        key = spec.get("key", "")
        _need(isinstance(key, str) and "\n" not in key and RE_KEY.fullmatch(key), f"{u}: chiave pubblica non valida")
        exp = spec.get("expire")
        _need(exp is None or (isinstance(exp, str) and RE_EXPIRE.fullmatch(exp)), f"{u}: expire deve essere AAAAMMGG")
    return maxdel


def _check_value(server, key, val, mode):
    if isinstance(val, str):
        return
    _need(isinstance(val, dict) and isinstance(val.get("secret"), str), f"{server}: valore non valido per {key}")
    if mode == "apply":
        _need(isinstance(val.get("value"), str) and val["value"] != "",
              f"{server}: manca il valore del segreto {val['secret']} (lo stato va generato in modalità apply)")


# ----------------------------------------------------------------------------- stato attuale
def sdir(name):
    return os.path.join(BASE, f"mcp-{name}")


def user_exists(u):
    try:
        pwd.getpwnam(u)
        return True
    except KeyError:
        return False


def server_exists(name):
    return user_exists(f"mcp-{name}") and os.path.isdir(sdir(name))


def mcp_users():
    try:
        return set(grp.getgrnam(USERS_GROUP).gr_mem)
    except KeyError:
        return set()


def user_servers(u):
    out = set()
    for g in grp.getgrall():
        m = re.fullmatch(r"mcp-(.+)-users", g.gr_name)
        if m and u in g.gr_mem:
            out.add(m.group(1))
    return out


def current_key(u):
    """(attiva, tipo+chiave, scadenza) oppure (None, None, None) se non c'è chiave."""
    for path, active in ((os.path.join(KEYS_DIR, u), True), (os.path.join(KEYS_DIR, f"{u}.disabled"), False)):
        if os.path.isfile(path):
            with open(path) as f:
                line = f.readline().strip()
            opts, _, rest = line.partition(" ")
            parts = rest.split()
            material = " ".join(parts[:2]) if len(parts) >= 2 else ""
            m = re.search(r'expiry-time="([0-9]{8})"', opts)
            return active, material, (m.group(1) if m else None)
    return None, None, None


def managed_state(name):
    try:
        with open(os.path.join(sdir(name), STATE_FILE)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def parse_env_file(path):
    vals = {}
    try:
        with open(path) as f:
            for line in f:
                m = re.match(r"\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.*)$", line.rstrip("\n"))
                if m:
                    try:
                        vals[m.group(1)] = " ".join(shlex.split(m.group(2)))
                    except ValueError:
                        vals[m.group(1)] = m.group(2)
    except OSError:
        pass
    return vals


def read_file(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


# ----------------------------------------------------------------------------- rendering
def subst(name, text):
    return text.replace("{dir}", sdir(name))


def value_of(name, val):
    return subst(name, val) if isinstance(val, str) else val.get("value")


def render_env(name, env):
    lines = [f"# Generato da mcp-reconcile per il server MCP '{name}': non modificare a mano"]
    for k in sorted(env):
        lines.append(f"export {k}={shlex.quote(value_of(name, env[k]))}")
    return "\n".join(lines) + "\n"


def render_run(name, cmd):
    d = sdir(name)
    argv = " ".join(shlex.quote(subst(name, c)) for c in cmd)
    return (
        "#!/bin/bash\n"
        f"# Generato da mcp-reconcile per il server MCP '{name}': non modificare a mano\n"
        "set -euo pipefail\n"
        "set -a\n"
        f"source {shlex.quote(os.path.join(d, name + '.env'))}\n"
        "set +a\n"
        f"cd {shlex.quote(d)}\n"
        f"exec {argv}\n"
    )


def install_hash(inst):
    return hashlib.sha256(json.dumps(inst, sort_keys=True).encode()).hexdigest()


def describe_install(inst):
    m = inst.get("method", "none")
    if m == "binary":
        return f"binario {inst['name']} (sha256 {inst['sha256'][:12]}…)"
    if m == "pip":
        return f"pacchetto {inst['package']} (Python {inst.get('python', '3.13')})"
    return "nessuna"


# ----------------------------------------------------------------------------- operazioni
def run(cmd, env=None):
    p = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, env=env)
    if p.returncode != 0:
        msg = (p.stderr or p.stdout).strip().splitlines()
        raise Fail(f"{os.path.basename(cmd[0])} {cmd[1] if len(cmd) > 1 else ''}: {msg[-1] if msg else 'errore'}")
    return p.stdout


def admin(*args):
    return run([MCP_ADMIN, *args])


def svc_ids(name):
    return pwd.getpwnam(f"mcp-{name}").pw_uid, grp.getgrnam(f"mcp-{name}").gr_gid


def write_atomic(path, content, uid, gid, mode):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(content)
        os.chown(tmp, uid, gid)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def fix_code_perms(name, path):
    _, gid = svc_ids(name)
    run(["chown", "-R", f"root:{gid}", path])
    run(["chmod", "-R", "u+rwX,g+rX,g-w,o-rwx", path])


def install_binary(name, inst):
    d = sdir(name)
    bindir = os.path.join(d, "bin")
    _, gid = svc_ids(name)
    os.makedirs(bindir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir="/var/tmp", prefix="mcp-dl-")
    try:
        h = hashlib.sha256()
        size = 0
        req = urllib.request.Request(inst["url"], headers={"User-Agent": "mcp-reconcile"})
        with urllib.request.urlopen(req, timeout=120) as r, os.fdopen(fd, "wb") as f:
            while True:
                chunk = r.read(1 << 16)
                if not chunk:
                    break
                size += len(chunk)
                if size > MAX_DOWNLOAD:
                    raise Fail("download troppo grande")
                h.update(chunk)
                f.write(chunk)
        if h.hexdigest() != inst["sha256"]:
            raise Fail(f"sha256 non corrispondente per {inst['url']}: scaricato {h.hexdigest()}")
        dest = os.path.join(bindir, inst["name"])
        os.chown(tmp, 0, gid)
        os.chmod(tmp, 0o750)
        shutil.move(tmp, dest)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    fix_code_perms(name, bindir)


def install_pip(name, inst):
    if not os.access(UV, os.X_OK):
        raise Fail(f"{UV} non trovato: installa uv sul server (vedi guida)")
    d = sdir(name)
    venv, pydir = os.path.join(d, "venv"), os.path.join(d, "python")
    shutil.rmtree(venv, ignore_errors=True)
    shutil.rmtree(pydir, ignore_errors=True)
    cache = tempfile.mkdtemp(prefix="mcp-uv-", dir="/var/tmp")
    env = dict(os.environ, UV_PYTHON_INSTALL_DIR=pydir, UV_CACHE_DIR=cache, HOME="/root")
    try:
        run([UV, "venv", "--quiet", "--python", inst.get("python", "3.13"), venv], env=env)
        run([UV, "pip", "install", "--quiet", "--python", os.path.join(venv, "bin", "python"), inst["package"]], env=env)
    finally:
        shutil.rmtree(cache, ignore_errors=True)
    fix_code_perms(name, venv)
    if os.path.isdir(pydir):
        fix_code_perms(name, pydir)


def do_install(name, inst):
    if inst["method"] == "binary":
        install_binary(name, inst)
    elif inst["method"] == "pip":
        install_pip(name, inst)


def save_state(name, inst):
    path = os.path.join(sdir(name), STATE_FILE)
    write_atomic(path, json.dumps({"install_hash": install_hash(inst)}) + "\n", 0, 0, 0o600)


def write_config(name, spec):
    uid, gid = svc_ids(name)
    d = sdir(name)
    write_atomic(os.path.join(d, f"{name}.env"), render_env(name, spec.get("env") or {}), 0, gid, 0o640)
    for fname, val in (spec.get("files") or {}).items():
        write_atomic(os.path.join(d, fname), value_of(name, val), 0, gid, 0o640)
    write_atomic(os.path.join(d, "run.sh"), render_run(name, spec["command"]), 0, gid, 0o750)


def with_keyfile(user, key, fn):
    fd, path = tempfile.mkstemp(prefix="mcp-key-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(key + "\n")
        return fn(path)
    finally:
        os.unlink(path)


# ----------------------------------------------------------------------------- piano
class Plan:
    ICON = {"+": "🟢", "~": "🟡", "-": "🔴", "!": "⚠️"}

    def __init__(self):
        self.actions = []
        self.notes = []

    def add(self, sym, text, fn=None):
        self.actions.append((sym, text, fn))

    def note(self, text):
        self.notes.append(text)


def plan_servers(plan, servers, mode):
    for name in sorted(servers):
        spec = servers[name]
        exists = server_exists(name)
        if spec.get("state") == "absent":
            if exists:
                plan.add("-", f"server `{name}`: dismesso (utente di servizio e regola sudo rimossi, cartella conservata)",
                         lambda n=name: admin("server-del", n))
            continue

        inst = spec.get("install") or {"method": "none"}
        st = managed_state(name) if exists else None
        if not exists:
            plan.add("+", f"server `{name}`: creazione", lambda n=name: admin("server-add", n))
        elif st is None:
            plan.add("~", f"server `{name}`: presa in gestione (run.sh e {name}.env verranno riscritti)")

        if inst["method"] != "none" and (st is None or st.get("install_hash") != install_hash(inst)):
            plan.add("+" if not exists else "~", f"server `{name}`: installazione {describe_install(inst)}",
                     lambda n=name, i=inst: do_install(n, i))

        d = sdir(name)
        env = spec.get("env") or {}
        files = spec.get("files") or {}
        changes = []
        if not exists:
            changes.append(f"{len(env)} variabili, {len(files)} file")
        else:
            cur = parse_env_file(os.path.join(d, f"{name}.env"))
            added = sorted(set(env) - set(cur))
            removed = sorted(set(cur) - set(env))
            modified = []
            for k in sorted(set(env) & set(cur)):
                v = env[k]
                if isinstance(v, str) or mode == "apply":
                    if value_of(name, v) != cur[k]:
                        modified.append(k + (" (segreto)" if not isinstance(v, str) else ""))
            for label, items in (("aggiunte", added), ("rimosse", removed), ("modificate", modified)):
                if items:
                    changes.append(f"variabili {label}: {', '.join(items)}")
            for fname, v in sorted(files.items()):
                cur_f = read_file(os.path.join(d, fname))
                if cur_f is None:
                    changes.append(f"nuovo file {fname}")
                elif (isinstance(v, str) or mode == "apply") and cur_f != value_of(name, v):
                    changes.append(f"file {fname} aggiornato")
            if read_file(os.path.join(d, "run.sh")) != render_run(name, spec["command"]):
                changes.append("run.sh aggiornato")
        if changes:
            plan.add("+" if not exists else "~", f"server `{name}`: configurazione ({'; '.join(changes)})",
                     lambda n=name, s=spec: write_config(n, s))
        elif st is None and exists:
            plan.add("~", f"server `{name}`: configurazione riscritta", lambda n=name, s=spec: write_config(n, s))
        # lo stato di gestione viene salvato sempre dopo le operazioni sul server
        plan.actions.append((None, None, lambda n=name, i=inst: save_state(n, i)))


def plan_users(plan, users, servers, maxdel):
    existing = mcp_users()
    revokes, deletes = [], []
    for u in sorted(users):
        spec = users[u]
        want_srv = set(spec["servers"])
        key, expire, enabled = spec["key"], spec.get("expire"), spec.get("enabled", True)
        material = " ".join(key.split()[:2])
        exp_args = ["--expire", expire] if expire else []

        if user_exists(u) and u not in existing:
            raise Fail(f"l'utente di sistema {u!r} esiste ma non è un utente MCP: scegli un altro nome")

        if u not in existing:
            srv = ",".join(sorted(want_srv))
            plan.add("+", f"utente `{u}`: creazione con accesso a {srv}" + (f", scadenza {expire}" if expire else ""),
                     lambda u=u, k=key, s=srv, e=exp_args:
                     with_keyfile(u, k, lambda p: admin("user-add", u, "--servers", s, "--pubkey", p, *e)))
            if not enabled:
                plan.add("~", f"utente `{u}`: sospeso", lambda u=u: admin("user-lock", u))
            continue

        cur_srv = user_servers(u)
        for s in sorted(want_srv - cur_srv):
            plan.add("+", f"utente `{u}`: accesso a `{s}`", lambda u=u, s=s: admin("user-grant", u, s))
        for s in sorted(cur_srv - want_srv):
            if servers.get(s, {}).get("state") == "absent":
                continue
            revokes.append(("-", f"utente `{u}`: revoca accesso a `{s}`", lambda u=u, s=s: admin("user-revoke", u, s)))

        active, cur_material, cur_exp = current_key(u)
        rotated = False
        if cur_material != material or cur_exp != expire:
            what = "nuova chiave" if cur_material != material else f"scadenza {expire or 'rimossa'}"
            plan.add("~", f"utente `{u}`: {what}",
                     lambda u=u, k=key, e=exp_args:
                     with_keyfile(u, k, lambda p: admin("user-rotate-key", u, "--pubkey", p, *e)))
            rotated = True
            active = True  # la rotazione riattiva la chiave
        if enabled and active is False:
            plan.add("~", f"utente `{u}`: riattivato", lambda u=u: admin("user-unlock", u))
        elif not enabled and (active or rotated):
            plan.add("~", f"utente `{u}`: sospeso", lambda u=u: admin("user-lock", u))

    for u in sorted(existing - set(users)):
        deletes.append(("-", f"utente `{u}`: eliminato", lambda u=u: admin("user-del", u)))
    if len(deletes) > maxdel:
        raise Fail(f"il piano elimina {len(deletes)} utenti (limite policy.max_user_deletions = {maxdel}): "
                   "se è voluto, alza il limite nel file di configurazione")
    for a in revokes + deletes:
        plan.add(*a)


def build_plan(state, mode):
    maxdel = validate(state, mode)
    if not os.access(GATEWAY, os.X_OK):
        raise Fail("mcp-admin setup non eseguito sul server")
    servers = state.get("servers") or {}
    users = state.get("users") or {}
    plan = Plan()
    live = {n: s for n, s in servers.items() if s.get("state", "present") == "present"}
    dead = {n: s for n, s in servers.items() if s.get("state") == "absent"}
    plan_servers(plan, live, mode)
    plan_users(plan, users, servers, maxdel)
    plan_servers(plan, dead, mode)
    if mode == "plan" and any((s.get("env") or s.get("files")) for s in live.values()):
        plan.note("I valori segreti non sono disponibili in fase di piano: vengono confrontati durante l'apply.")
    unmanaged = sorted(
        os.path.basename(p)[4:] for p in (os.path.join(BASE, x) for x in os.listdir(BASE))
        if os.path.basename(p).startswith("mcp-") and os.path.isdir(p)
        and os.path.basename(p)[4:] not in servers and user_exists(os.path.basename(p))
    )
    for n in unmanaged:
        plan.note(f"Il server `{n}` esiste sul server ma non è dichiarato nel file: viene ignorato.")
    return plan


# ----------------------------------------------------------------------------- main
def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("plan", "apply"):
        print(__doc__, file=sys.stderr)
        return 2
    mode = sys.argv[1]
    if os.geteuid() != 0:
        print("mcp-reconcile deve essere eseguito come root", file=sys.stderr)
        return 2

    lock = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("❌ un'altra esecuzione di mcp-reconcile è in corso", file=sys.stderr)
        return 1

    raw = sys.stdin.read(MAX_INPUT + 1)
    if len(raw) > MAX_INPUT:
        print("❌ stato troppo grande", file=sys.stderr)
        return 1
    try:
        state = json.loads(raw)
        plan = build_plan(state, mode)
    except (ValueError, Fail) as e:
        print(f"### ❌ Stato non valido\n\n{e}")
        return 1

    visible = [a for a in plan.actions if a[0]]
    title = "Piano" if mode == "plan" else "Applicazione"
    print(f"### {title} MCP — {len(visible)} modifiche\n")
    if not visible:
        print("Nessuna modifica: il server è già allineato alla configurazione.\n")

    rc = 0
    for sym, text, fn in plan.actions:
        if mode == "plan":
            if sym:
                print(f"- {Plan.ICON[sym]} {text}")
            continue
        try:
            if fn:
                fn()
            if sym:
                print(f"- ✅ {Plan.ICON[sym]} {text}")
        except Exception as e:  # noqa: BLE001 — qualsiasi errore interrompe l'applicazione
            print(f"- ❌ {Plan.ICON.get(sym, '')} {text or 'salvataggio stato'}: {e}")
            print("\n**Applicazione interrotta**: le operazioni successive non sono state eseguite.")
            rc = 1
            break

    for n in plan.notes:
        print(f"\n> {n}")
    if rc == 0 and mode == "apply":
        subprocess.run(["logger", "-t", "mcp-reconcile", f"apply completato: {len(visible)} modifiche"], check=False)
    return rc


if __name__ == "__main__":
    sys.exit(main())
```

#### 12.11.2 install-deploy.sh (server)

`server/install-deploy.sh`

```bash
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
```

#### 12.11.3 build_state.py (pipeline)

`scripts/build_state.py`

```python
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
```

#### 12.11.4 ssh_run.sh (pipeline)

`scripts/ssh_run.sh`

```bash
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
```

#### 12.11.5 Workflow di piano

`.github/workflows/mcp-plan.yml`

```yaml
# Validazione e piano (sola lettura) su ogni pull request, ogni notte e a richiesta.
# Il piano notturno segnala eventuali modifiche fatte a mano sul server (drift).
name: MCP · validazione e piano

on:
  pull_request:
    branches: [main]
    paths: ["config/**", "keys/**", "scripts/**", ".github/workflows/mcp-*.yml"]
  schedule:
    - cron: "30 5 * * *"
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: mcp-plan-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

jobs:
  plan:
    # niente esecuzioni per PR provenienti da fork
    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository
    runs-on: [self-hosted, linux, mcp-plan]
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false

      - name: Dipendenze Python
        run: |
          python3 -m venv "$RUNNER_TEMP/venv"
          "$RUNNER_TEMP/venv/bin/pip" install --quiet pyyaml==6.0.2
          echo "PYTHON=$RUNNER_TEMP/venv/bin/python" >> "$GITHUB_ENV"

      - name: Validazione dei file YAML e delle chiavi
        run: $PYTHON scripts/build_state.py validate

      - name: Piano sul server MCP (sola lettura)
        env:
          MCP_SSH_KEY: ${{ secrets.MCP_PLAN_SSH_KEY }}
          MCP_SSH_KNOWN_HOSTS: ${{ vars.MCP_SSH_KNOWN_HOSTS }}
          MCP_SERVER_HOST: ${{ vars.MCP_SERVER_HOST }}
        run: bash scripts/ssh_run.sh plan
```

#### 12.11.6 Workflow di deploy

`.github/workflows/mcp-deploy.yml`

```yaml
# Deploy dopo il merge su main: piano -> approvazione -> applicazione.
# Il job "apply" usa l'environment protetto "mcp-production": si ferma finché un
# revisore autorizzato non approva, e solo dopo riceve i secret (chiave apply e credenziali).
name: MCP · deploy

on:
  push:
    branches: [main]
    paths: ["config/**", "keys/**", "scripts/**", ".github/workflows/mcp-*.yml"]
  # da usare anche dopo aver ruotato un secret su GitHub
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: mcp-deploy
  cancel-in-progress: false

jobs:
  plan:
    runs-on: [self-hosted, linux, mcp-plan]
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false

      - name: Dipendenze Python
        run: |
          python3 -m venv "$RUNNER_TEMP/venv"
          "$RUNNER_TEMP/venv/bin/pip" install --quiet pyyaml==6.0.2
          echo "PYTHON=$RUNNER_TEMP/venv/bin/python" >> "$GITHUB_ENV"

      - name: Validazione
        run: $PYTHON scripts/build_state.py validate

      - name: Piano (da controllare prima di approvare)
        env:
          MCP_SSH_KEY: ${{ secrets.MCP_PLAN_SSH_KEY }}
          MCP_SSH_KNOWN_HOSTS: ${{ vars.MCP_SSH_KNOWN_HOSTS }}
          MCP_SERVER_HOST: ${{ vars.MCP_SERVER_HOST }}
        run: bash scripts/ssh_run.sh plan

  apply:
    needs: plan
    runs-on: [self-hosted, linux, mcp-apply]
    environment:
      name: mcp-production
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false

      - name: Dipendenze Python
        run: |
          python3 -m venv "$RUNNER_TEMP/venv"
          "$RUNNER_TEMP/venv/bin/pip" install --quiet pyyaml==6.0.2
          echo "PYTHON=$RUNNER_TEMP/venv/bin/python" >> "$GITHUB_ENV"

      - name: Validazione
        run: $PYTHON scripts/build_state.py validate

      - name: Applicazione sul server MCP
        env:
          MCP_SSH_KEY: ${{ secrets.MCP_APPLY_SSH_KEY }}
          MCP_SSH_KNOWN_HOSTS: ${{ vars.MCP_SSH_KNOWN_HOSTS }}
          MCP_SERVER_HOST: ${{ vars.MCP_SERVER_HOST }}
          SECRETS_JSON: ${{ toJSON(secrets) }}
        run: bash scripts/ssh_run.sh apply
```

#### 12.11.7 File di configurazione di esempio: servers.yaml

`config/servers.yaml`

```yaml
# =============================================================================
# Server MCP gestiti dalla pipeline
#
# - I valori { secret: NOME } vengono letti dai secret dell'environment GitHub
#   "mcp-production" e non compaiono mai nel repository né nei log.
# - {dir} viene sostituito con la cartella del server (/opt/mcp-NOME).
# - Per dismettere un server non cancellarlo: imposta  state: absent
# =============================================================================

policy:
  # blocca l'apply se in un colpo solo verrebbero eliminati più utenti di così
  max_user_deletions: 3

servers:

  wazuh:
    install:
      method: binary
      # scegli la release da https://github.com/gbrigandi/mcp-server-wazuh/releases
      url: https://github.com/gbrigandi/mcp-server-wazuh/releases/download/<VERSIONE>/mcp-server-wazuh-linux-amd64
      # calcolalo con:  curl -sL <url> | sha256sum
      sha256: "<SHA256>"
      name: mcp-server-wazuh
    command: ["{dir}/bin/mcp-server-wazuh", "--transport", "stdio"]
    env:
      WAZUH_API_HOST: 192.168.10.50
      WAZUH_API_PORT: 55000
      WAZUH_API_USERNAME: { secret: WAZUH_API_USERNAME }
      WAZUH_API_PASSWORD: { secret: WAZUH_API_PASSWORD }
      WAZUH_INDEXER_HOST: 192.168.10.50
      WAZUH_INDEXER_PORT: 9200
      WAZUH_INDEXER_USERNAME: { secret: WAZUH_INDEXER_USERNAME }
      WAZUH_INDEXER_PASSWORD: { secret: WAZUH_INDEXER_PASSWORD }
      WAZUH_VERIFY_SSL: false
      RUST_LOG: warn

  unifi:
    install:
      method: pip
      # versione fissa: controlla l'ultima su https://pypi.org/project/unifi-network-mcp/
      package: unifi-network-mcp==<VERSIONE>
      python: "3.13"
    command: ["{dir}/venv/bin/unifi-network-mcp"]
    env:
      UNIFI_HOST: 192.168.10.1
      UNIFI_USERNAME: { secret: UNIFI_USERNAME }
      UNIFI_PASSWORD_FILE: "{dir}/password"
      UNIFI_VERIFY_SSL: false
    files:
      # file 640 root:mcp-unifi con il contenuto del secret
      password: { secret: UNIFI_PASSWORD }

  # Esempio di server dismesso:
  # vecchio-server:
  #   state: absent
```

#### 12.11.8 File di configurazione di esempio: users.yaml

`config/users.yaml`

```yaml
# =============================================================================
# Utenti MCP gestiti dalla pipeline
#
# - Aggiungere un utente:  metti la sua chiave pubblica in keys/NOME.pub
#                          e aggiungi una voce qui sotto.
# - Togliere un server:    rimuovilo dalla lista "servers".
# - Sospendere:            enabled: false   (la chiave resta, l'accesso no)
# - Deprovisioning:        cancella la voce (e il file .pub): l'utente viene eliminato.
# - La chiave privata resta sempre sul PC dell'utente: qui solo chiavi pubbliche.
# =============================================================================

users:

  alice:
    servers: [wazuh, unifi]
    expire: 2027-12-31          # facoltativo: dopo questa data la chiave non vale più

  bob:
    servers: [wazuh]

  # carla:
  #   servers: [unifi]
  #   enabled: false
  #   key_file: keys/carla-laptop.pub   # facoltativo, predefinito keys/NOME.pub
```

#### 12.11.9 CODEOWNERS

`.github/CODEOWNERS`

```
# Ogni modifica a configurazione, chiavi, script e workflow richiede
# l'approvazione del team di sicurezza (sostituisci con il tuo team o utenti).
/config/     @TUA-ORG/sicurezza
/keys/       @TUA-ORG/sicurezza
/scripts/    @TUA-ORG/sicurezza
/server/     @TUA-ORG/sicurezza
/.github/    @TUA-ORG/sicurezza
```

La versione aggiornata di `mcp-admin`, compatibile con i server gestiti dalla pipeline, è nella [sezione 11.9](#119-lo-script-mcp-admin).

---

## Riferimenti

- Claude Code e MCP: <https://docs.claude.com/en/docs/claude-code/mcp>
- Server MCP per Wazuh: <https://github.com/gbrigandi/mcp-server-wazuh>
- Server MCP per UniFi: <https://github.com/sirkirby/unifi-mcp>
- Environment e approvazioni di GitHub Actions: <https://docs.github.com/actions/deployment/targeting-different-environments/using-environments-for-deployment>
- Runner self-hosted: <https://docs.github.com/actions/hosting-your-own-runners>
