# Piattaforma MCP interna — Manuale di installazione e d'uso

Questo manuale descrive come installare, configurare e usare una piattaforma che ospita **server MCP** (Model Context Protocol) su un server Linux interno. La piattaforma li rende disponibili a più utenti tramite **Claude Code** e li gestisce in modo dichiarativo con **GitHub Actions**.

---

## Indice

1. [Panoramica](#1-panoramica)
2. [Requisiti](#2-requisiti)
3. [Installazione del server MCP](#3-installazione-del-server-mcp)
4. [Installazione del runner GitHub Actions](#4-installazione-del-runner-github-actions)
5. [Configurazione del repository GitHub](#5-configurazione-del-repository-github)
6. [Riferimento della configurazione dichiarativa](#6-riferimento-della-configurazione-dichiarativa)
7. [Operazioni di amministrazione](#7-operazioni-di-amministrazione)
8. [Guida per l'utente finale](#8-guida-per-lutente-finale)
9. [Gestione manuale con mcp-admin](#9-gestione-manuale-con-mcp-admin)
10. [Monitoraggio, audit e verifiche di sicurezza](#10-monitoraggio-audit-e-verifiche-di-sicurezza)
11. [Risoluzione dei problemi](#11-risoluzione-dei-problemi)
12. [Configurazione dei server MCP: Wazuh, UniFi, Proxmox](#12-configurazione-dei-server-mcp-wazuh-unifi-proxmox)
- [Appendice A — Codice sorgente](#appendice-a--codice-sorgente)
- [Appendice B — Evoluzione: segreti in HashiCorp Vault](#appendice-b--evoluzione-segreti-in-hashicorp-vault)
- [Riferimenti](#riferimenti)

---

### Convenzioni

I comandi preceduti da `sudo` vanno eseguiti sul server indicato nel paragrafo da un utente amministratore. Gli altri comandi vanno eseguiti come utente normale. I valori in maiuscolo sono **segnaposto** da sostituire:

| Segnaposto | Significato |
|---|---|
| `IP-SERVER-MCP` | IP del server che ospita i server MCP |
| `IP-RUNNER` | IP della macchina con il runner GitHub Actions |
| `TUA-ORG/NOME-REPO` | organizzazione e nome del repository GitHub di configurazione |
| `NOME` | nome di un server MCP (es. `proxmox`) |
| `UTENTE` | nome di un utente della piattaforma (es. `giorgio`) |
| `<VERSIONE>`, `<SHA256>` | versione e impronta di un pacchetto o binario |

---

## 1. Panoramica

### 1.1 A cosa serve

Un server MCP espone a un assistente AI degli strumenti per interrogare o gestire un sistema, per esempio un SIEM, un hypervisor o una rete. Questa piattaforma consente di:

- installare più server MCP su un'unica macchina interna, ciascuno isolato con il proprio utente di servizio e le proprie credenziali;
- dare accesso a più persone, ognuna autorizzata solo ai server MCP che le servono;
- tenere le credenziali dei sistemi (API key, token, password) **fuori** dai PC degli utenti;
- gestire server e utenti con **file YAML versionati su GitHub**, con piano delle modifiche, revisione e approvazione prima di ogni applicazione.

### 1.2 Architettura

```
  PC utente                         Server MCP interno                                   Sistemi
┌──────────────┐  SSH (chiave)  ┌──────────────────────────────────────────────┐
│ Claude Code  │ ─────────────► │ sshd  ── Match Group mcp-users               │
│              │  "ssh … NOME"  │   └► mcp-gateway   (è autorizzato a NOME?)   │
└──────────────┘                │        └► sudo -u mcp-NOME /opt/mcp-NOME/run.sh ──► API di NOME
                                │              (legge NOME.env, avvia il server │   (Wazuh, UniFi,
                                │               MCP su stdin/stdout)            │    Proxmox, …)
                                └──────────────────────────────────────────────┘
                                                     ▲
 GitHub                        Runner interno        │ SSH (utente mcp-deploy, comando forzato)
┌──────────────────┐  job   ┌──────────────────┐     │
│ repo di config.  │ ─────► │ build_state.py   │ ────┘  mcp-reconcile plan | apply
│ YAML + chiavi    │        │ ssh_run.sh       │
│ secret, approvaz.│        └──────────────────┘
└──────────────────┘
```

Il client non si collega mai direttamente ai sistemi. Apre una sessione SSH verso il server MCP chiedendo **solo il nome** del server MCP da usare. Il gateway verifica l'autorizzazione e avvia il server MCP con l'utente di servizio corretto. Il protocollo MCP viaggia poi nella sessione SSH.

### 1.3 Componenti

| Componente | Dove | Funzione |
|---|---|---|
| `mcp-gateway` | server MCP, `/usr/local/bin` | comando forzato per gli utenti: accetta solo il nome di un server autorizzato e lo avvia |
| `mcp-admin` | server MCP, `/usr/local/sbin` | gestione di server MCP, utenti, chiavi e regole sudo |
| `mcp-reconcile` | server MCP, `/usr/local/sbin` | confronta lo stato desiderato con quello reale, mostra il piano, applica le differenze |
| `install-deploy.sh` | repository, `server/` | prepara il server MCP per la pipeline (utente `mcp-deploy`, chiavi, sudo, sshd) |
| `build_state.py` | repository, `scripts/` | valida i YAML e produce lo stato JSON, con o senza segreti |
| `ssh_run.sh` | repository, `scripts/` | invia lo stato al server via SSH e pubblica l'esito nel riepilogo del job |
| `mcp-plan.yml` | repository, workflow | validazione e piano su ogni PR, ogni notte e a richiesta |
| `mcp-deploy.yml` | repository, workflow | dopo il merge su `main`: piano → approvazione → applicazione |

### 1.4 Convenzioni sul server MCP

Per un server MCP chiamato `NOME`:

| Elemento | Valore |
|---|---|
| Utente di servizio | `mcp-NOME` (senza shell, possiede solo la propria cartella) |
| Cartella | `/opt/mcp-NOME` (permessi `750`) |
| Codice | `/opt/mcp-NOME/bin/` o `/opt/mcp-NOME/venv/`, di proprietà di root |
| Avvio | `/opt/mcp-NOME/run.sh` (`750 root:mcp-NOME`) |
| Variabili e credenziali | `/opt/mcp-NOME/NOME.env` e file segreti (`640 root:mcp-NOME`) |
| Gruppo degli utenti autorizzati | `mcp-NOME-users` |
| Regola sudo | `/etc/sudoers.d/mcp-NOME` (consente solo `run.sh`) |

Per gli utenti:

| Elemento | Valore |
|---|---|
| Gruppo | `mcp-users` (sshd impone il gateway, niente shell né forwarding) |
| Chiave autorizzata | `/etc/ssh/mcp_keys/UTENTE` (di root, con scadenza opzionale) |

### 1.5 Modello di sicurezza

| Livello | Protezione |
|---|---|
| Rete | SSH raggiungibile solo dalle reti autorizzate; le porte dei sistemi sono aperte solo verso il server MCP |
| Autenticazione | solo chiavi SSH; la chiave privata resta sul PC dell'utente |
| Utenti | nessuna shell, nessun TTY, nessun tunnel: possono solo avviare i server MCP autorizzati |
| Isolamento tra server | ogni server MCP ha il proprio utente di servizio e non può leggere le credenziali degli altri |
| Credenziali | leggibili solo dall'utente di servizio; nel repository compaiono solo come riferimenti |
| Account sui sistemi | dedicati e, dove possibile, in sola lettura |
| Pipeline | PR con revisione, piano leggibile, approvazione, chiavi di piano e di applicazione separate e vincolate dal server |
| Tracciabilità | cronologia Git, approvazioni GitHub, log di gateway, reconcile, sudo e sshd, auditd |

Tutti gli utenti dello stesso server MCP condividono l'account sul sistema di destinazione. Nei log di quel sistema compare quindi sempre lo stesso account. Per sapere *chi* ha usato il server, fai riferimento ai log del gateway (capitolo 10). Se servono permessi diversi per persona, crea due server MCP distinti, per esempio `proxmox` in sola lettura e `proxmox-admin`, ciascuno con il proprio account e il proprio gruppo.

### 1.6 Ruoli

| Ruolo | Attività |
|---|---|
| Amministratore della piattaforma | installa e mantiene server MCP e runner, gestisce le credenziali nei secret |
| Revisore / approvatore | revisiona le PR (CODEOWNERS) e approva i deploy |
| Utente | genera la propria chiave, configura Claude Code e usa i server MCP autorizzati |

---

## 2. Requisiti

### 2.1 Server MCP

Serve un server Linux dedicato: Fedora, RHEL e derivate, oppure Debian e Ubuntu. Deve avere:

- `openssh-server`, `sudo`, `python3` (3.8 o superiore);
- `uv` in `/usr/local/bin` per i server MCP installati da PyPI;
- SELinux o AppArmor attivi;
- accesso in rete verso i sistemi da interrogare;
- accesso in uscita verso GitHub e PyPI per le installazioni automatiche.

### 2.2 Runner GitHub Actions

Il server MCP sta nella rete interna, quindi i runner ospitati da GitHub non lo raggiungono. Serve un **runner self-hosted**, preferibilmente su una VM dedicata. Il manuale usa Fedora come esempio (capitolo 4).

In un ambiente di test il runner può stare sulla stessa macchina del server MCP. In produzione conviene separarlo: chi compromette il runner ottiene la chiave di applicazione e le credenziali in transito.

### 2.3 GitHub

Serve un repository **privato** per la configurazione. L'approvazione nativa dei deploy usa i *required reviewers* degli environment:

- nei repository privati questa funzione richiede **GitHub Enterprise**;
- con Free, Pro e Team è disponibile solo per i repository pubblici;
- environment, secret di environment e restrizioni sui branch sono invece disponibili anche con Pro e Team.

Su Team o Pro l'approvazione è affidata alla revisione obbligatoria delle PR da parte dei CODEOWNERS (paragrafo 5.4).

### 2.4 Client degli utenti

Servono Linux, macOS o Windows con OpenSSH e **Claude Code**.

### 2.5 Sistemi di destinazione

Per ogni sistema serve un account **dedicato** alla piattaforma, con i permessi minimi necessari (idealmente sola lettura) e raggiungibile dal server MCP. Il capitolo 12 descrive gli account per Wazuh, UniFi e Proxmox.

---

## 3. Installazione del server MCP

L'installazione si fa una volta sola. Gli script si trovano nella cartella `server/` del repository di configurazione (capitolo 5): copiala sul server MCP prima di iniziare, per esempio in `~/mcp-setup`. Se il runner è sulla stessa macchina, **non lavorare nella cartella `_work` del runner**: copiala altrove.

```bash
sudo cp -r /opt/actions-runner/_work/NOME-REPO/NOME-REPO/server ~/mcp-setup   # solo se il repository è già lì
sudo chown -R "$USER": ~/mcp-setup
```

### 3.1 Pacchetti di base

Fedora / RHEL:

```bash
sudo dnf install -y python3 sudo openssh-server policycoreutils-python-utils audit
sudo systemctl enable --now sshd
```

Debian / Ubuntu:

```bash
sudo apt install -y python3 sudo openssh-server auditd
```

Installa `uv` a livello di sistema (serve per i server MCP distribuiti su PyPI):

```bash
curl -LsSf https://astral.sh/uv/install.sh | sudo env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh
```

### 3.2 Hardening del sistema

> ⚠️ Prima di modificare SSH verifica di poter accedere come amministratore **con chiave**. Tieni aperta una sessione finché non hai controllato che una nuova connessione funziona.

**Aggiornamenti automatici.** Su Fedora recente usa `dnf5-plugin-automatic`, su RHEL e derivate `dnf-automatic` (con `apply_updates = yes` e `systemctl enable --now dnf-automatic.timer`), su Debian e Ubuntu `unattended-upgrades` (`sudo dpkg-reconfigure -plow unattended-upgrades`).

**SSH globale.** Crea il gruppo degli amministratori e aggiungiti:

```bash
sudo groupadd ssh-admins
sudo usermod -aG ssh-admins "$USER"
```

Crea il file `/etc/ssh/sshd_config.d/00-hardening.conf`:

```
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
AllowGroups ssh-admins mcp-users mcp-deploy
```

Poi verifica la configurazione e ricaricala:

```bash
sudo sshd -t && sudo systemctl reload sshd            # Debian/Ubuntu: reload ssh
sudo sshd -T | grep -Ei 'permitrootlogin|passwordauthentication|allowgroups'
```

In sshd vale il primo valore letto: il prefisso `00-` fa prevalere queste impostazioni sugli altri file della cartella.

**Firewall.** Consenti SSH solo dalle reti dei client e dall'IP del runner. Con firewalld:

```bash
sudo firewall-cmd --permanent --remove-service=ssh
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="RETE-CLIENT/24" service name="ssh" accept'
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="IP-RUNNER" service name="ssh" accept'
sudo firewall-cmd --reload
```

Con ufw:

```bash
sudo ufw default deny incoming
sudo ufw allow from RETE-CLIENT/24 to any port 22 proto tcp
sudo ufw allow from IP-RUNNER to any port 22 proto tcp
sudo ufw enable
```

Per un livello in più puoi limitare anche il traffico in uscita: il server MCP deve raggiungere solo i sistemi di destinazione, il DNS, i repository dei pacchetti, GitHub e PyPI.

**fail2ban.** Installalo e crea `/etc/fail2ban/jail.d/sshd.local`:

```ini
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
```

Poi attivalo:

```bash
sudo systemctl enable --now fail2ban
```

**SELinux o AppArmor.** Lasciali attivi: su Fedora e RHEL `getenforce` deve rispondere `Enforcing`. In caso di problemi di accesso a file, ripristina i contesti con `restorecon` invece di disattivarli.

**auditd.** Crea `/etc/audit/rules.d/mcp.rules`:

```
-w /etc/ssh/mcp_keys/ -p wa -k mcp-keys
-w /etc/ssh/mcp_deploy_keys -p wa -k mcp-deploy-keys
-w /etc/sudoers.d/ -p wa -k mcp-sudoers
-w /etc/ssh/sshd_config.d/ -p wa -k sshd-config
-w /usr/local/bin/mcp-gateway -p wa -k mcp-bin
-w /usr/local/sbin/ -p wa -k mcp-bin
# una riga per ogni server MCP (aggiungila quando crei il server)
-w /opt/mcp-NOME/ -p wa -k mcp-NOME
```

Poi carica le regole:

```bash
sudo augenrules --load
```

**Monitoraggio.** Se hai un SIEM (per esempio Wazuh), installa il suo agente sul server MCP. Così accessi SSH, uso di sudo, eventi auditd e integrità dei file in `/opt/mcp-*`, `/etc/ssh` e `/etc/sudoers.d` arrivano alla console centrale.

**Altro.** Tieni l'orario sincronizzato con chrony, disattiva i servizi non necessari e fai backup cifrati di `/opt/mcp-*`, `/etc/ssh/mcp_keys` e `/etc/ssh/mcp_deploy_keys`.

### 3.3 Chiavi della pipeline

La pipeline usa **due** chiavi SSH distinte. La chiave *plan* può solo leggere e calcolare il piano; la chiave *apply* può applicare le modifiche. Generale su una postazione di amministrazione, oppure temporaneamente sul server in una cartella protetta:

```bash
mkdir -m 700 ~/pipeline-keys && cd ~/pipeline-keys
ssh-keygen -t ed25519 -N "" -C "mcp-plan"  -f mcp_plan
ssh-keygen -t ed25519 -N "" -C "mcp-apply" -f mcp_apply
```

Le chiavi private verranno caricate nei secret di GitHub (paragrafo 5.3) e poi distrutte.

### 3.4 Installazione della piattaforma

Dalla cartella `server/` copiata sul server:

```bash
cd ~/mcp-setup
sudo ./install-deploy.sh \
  --plan-key  ~/pipeline-keys/mcp_plan.pub \
  --apply-key ~/pipeline-keys/mcp_apply.pub \
  --from "IP-RUNNER"
```

In `--from` indica gli indirizzi da cui si collega il runner. Se il runner è **sulla stessa macchina**, usa l'IP del server più `127.0.0.1`, per esempio `--from "192.168.10.40,127.0.0.1"`.

Lo script:

1. installa `mcp-admin` e `mcp-reconcile` in `/usr/local/sbin`;
2. esegue `mcp-admin setup`, cioè crea il gruppo `mcp-users`, installa il gateway e il blocco sshd per gli utenti;
3. crea l'utente `mcp-deploy`, senza password;
4. scrive la regola sudo, che consente **solo** `mcp-reconcile plan` e `mcp-reconcile apply`;
5. scrive `/etc/ssh/mcp_deploy_keys`, con ogni chiave vincolata al proprio comando e agli IP del runner;
6. aggiunge il blocco sshd per `mcp-deploy`, lo verifica con `sshd -t` (annullando la modifica se non è valido) e ricarica sshd;
7. alla fine stampa la chiave host del server.

Lo script è rieseguibile. Rilancialo per aggiornare gli script dopo una modifica al repository, per sostituire le chiavi della pipeline o per cambiare l'IP del runner.

### 3.5 Verifica

Dalla macchina del runner, con la chiave plan:

```bash
echo '{}' | ssh -i ~/pipeline-keys/mcp_plan -o StrictHostKeyChecking=accept-new -T mcp-deploy@IP-SERVER-MCP
```

Il risultato atteso è:

```
### ❌ Stato non valido

versione dello stato non supportata
```

Questo errore conferma che SSH, sudo e `mcp-reconcile` funzionano. Se invece compare `Permission denied (publickey)`, controlla `--from` e la chiave usata.

---

## 4. Installazione del runner GitHub Actions

L'esempio è su **Fedora Server**. Il runner si collega **in uscita** a GitHub (HTTPS 443), quindi non richiede porte in ingresso.

### 4.1 Prerequisiti e utente dedicato

```bash
sudo dnf install -y git curl tar python3 openssh-clients policycoreutils-python-utils
sudo useradd --system --create-home --home-dir /opt/actions-runner \
             --shell /bin/bash --comment "GitHub Actions runner" github-runner
```

L'utente del runner **non** deve avere sudo né appartenere a `wheel`.

### 4.2 Download e registrazione

Nel repository apri **Settings → Actions → Runners → New self-hosted runner** e seleziona *Linux x64*. Copia i comandi di download, che contengono la versione e lo sha256 aggiornati, ed eseguili come utente del runner:

```bash
sudo -iu github-runner
cd /opt/actions-runner
curl -o actions-runner-linux-x64-<VERSIONE>.tar.gz -L \
  https://github.com/actions/runner/releases/download/v<VERSIONE>/actions-runner-linux-x64-<VERSIONE>.tar.gz
echo "<SHA256>  actions-runner-linux-x64-<VERSIONE>.tar.gz" | sha256sum -c
tar xzf actions-runner-linux-x64-<VERSIONE>.tar.gz
exit

sudo /opt/actions-runner/bin/installdependencies.sh
```

Registra il runner con il token mostrato nella stessa pagina (scade dopo circa un'ora) e con le etichette usate dai workflow:

```bash
sudo -iu github-runner
cd /opt/actions-runner
./config.sh --url https://github.com/TUA-ORG/NOME-REPO --token <TOKEN> \
            --name mcp-runner-01 --labels mcp-plan,mcp-apply --work _work --unattended
exit
```

Con due runner separati, che è la soluzione consigliata, registra il primo con `--labels mcp-plan` e il secondo con `--labels mcp-apply`.

### 4.3 Servizio systemd e SELinux

```bash
cd /opt/actions-runner
sudo ./svc.sh install github-runner
sudo semanage fcontext --add --type initrc_exec_t '/opt/actions-runner/runsvc.sh'
sudo restorecon -v /opt/actions-runner/runsvc.sh
sudo ./svc.sh start
sudo ./svc.sh status
```

Senza le due righe `semanage` e `restorecon`, SELinux impedisce a systemd di eseguire lo script del runner e il servizio fallisce con `status=203/EXEC`.

Su GitHub il runner deve comparire come **Idle**. Per seguire i log:

```bash
journalctl -u 'actions.runner.*' -f
```

### 4.4 Sicurezza del runner

Proteggi il runner come il server MCP:

- aggiornamenti automatici e hardening SSH (paragrafo 3.2);
- firewall senza porte in ingresso, salvo SSH di amministrazione;
- in uscita solo HTTPS verso GitHub e SSH verso il server MCP;
- agente del SIEM.

Il runner si aggiorna da solo. Puoi valutare i runner effimeri (`--ephemeral`), che eseguono un solo job e poi si deregistrano. Usa il runner **solo** con il repository di configurazione.

### 4.5 Rimozione

```bash
cd /opt/actions-runner
sudo ./svc.sh stop && sudo ./svc.sh uninstall
sudo -iu github-runner /opt/actions-runner/config.sh remove --token <TOKEN_DI_RIMOZIONE>
```

---

## 5. Configurazione del repository GitHub

### 5.1 Struttura

```
NOME-REPO/
├── .github/
│   ├── CODEOWNERS
│   └── workflows/
│       ├── mcp-plan.yml        # PR, notturno, manuale: validazione + piano
│       └── mcp-deploy.yml      # merge su main: piano → approvazione → apply
├── config/
│   ├── servers.yaml            # server MCP
│   └── users.yaml              # utenti e autorizzazioni
├── keys/                       # chiavi pubbliche degli utenti (UTENTE.pub)
├── scripts/
│   ├── build_state.py
│   └── ssh_run.sh
└── server/                     # script da installare sul server MCP
    ├── mcp-admin
    ├── mcp-reconcile
    └── install-deploy.sh
```

Il codice di tutti i file è nell'[Appendice A](#appendice-a--codice-sorgente).

### 5.2 Environment `mcp-production`

In **Settings → Environments → New environment** crea l'environment `mcp-production` e configuralo così:

- **Required reviewers**: le persone o il team che approvano i deploy, con *Prevent self-review* attivo. Se il piano GitHub non lo consente, vedi il paragrafo 2.3.
- **Deployment branches and tags**: *Selected branches*, solo `main`.

### 5.3 Secret e variabili

| Nome | Tipo | Dove | Contenuto |
|---|---|---|---|
| `MCP_PLAN_SSH_KEY` | secret | **repository** | chiave privata `mcp_plan`, comprese le righe BEGIN/END |
| `MCP_APPLY_SSH_KEY` | secret | environment `mcp-production` | chiave privata `mcp_apply` |
| credenziali dei sistemi | secret | environment `mcp-production` | un secret per ogni `{ secret: NOME }` usato nei YAML |
| `MCP_SERVER_HOST` | variabile | repository | IP o nome del server MCP |
| `MCP_SSH_KNOWN_HOSTS` | variabile | repository | riga known_hosts del server MCP |

I secret si creano in **Settings → Secrets and variables → Actions**: scheda *Secrets* per quelli del repository, pagina dell'environment per quelli di `mcp-production`. Le variabili si creano nella scheda **Variables**.

Con la CLI `gh`, da installare su una postazione di amministrazione e non sul runner:

```bash
gh secret set MCP_PLAN_SSH_KEY < mcp_plan
gh secret set MCP_APPLY_SSH_KEY --env mcp-production < mcp_apply
gh secret set NOME_SECRET --env mcp-production            # chiede il valore senza mostrarlo
gh variable set MCP_SERVER_HOST --body "IP-SERVER-MCP"
```

**Riga known_hosts.** Ricavala con `ssh-keyscan`, così il nome iniziale coincide con `MCP_SERVER_HOST`:

```bash
ssh-keyscan -t ed25519 IP-SERVER-MCP 2>/dev/null
```

Prima di salvarla, confronta la fingerprint con quella reale del server. Le due righe devono coincidere:

```bash
ssh-keyscan -t ed25519 IP-SERVER-MCP 2>/dev/null | ssh-keygen -lf -     # dal runner
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub                    # sul server
```

Poi salva la riga e distruggi le chiavi private:

```bash
gh variable set MCP_SSH_KNOWN_HOSTS --body "IP-SERVER-MCP ssh-ed25519 AAAA..."
shred -u ~/pipeline-keys/mcp_plan ~/pipeline-keys/mcp_apply
```

Verifica infine che tutto sia al posto giusto:

```bash
gh secret list                         # deve contenere MCP_PLAN_SSH_KEY
gh secret list --env mcp-production    # MCP_APPLY_SSH_KEY e le credenziali
gh variable list                       # MCP_SERVER_HOST e MCP_SSH_KNOWN_HOSTS
```

### 5.4 Regole del branch `main` e CODEOWNERS

In **Settings → Rules → Rulesets** (oppure *Branch protection*) crea per `main` queste regole:

- pull request obbligatoria con almeno un'approvazione;
- revisione obbligatoria dei **Code Owners**;
- *Dismiss stale approvals* ai nuovi commit;
- status check obbligatorio `plan`;
- niente force push né cancellazione del branch;
- regole valide anche per gli amministratori.

Nel file `.github/CODEOWNERS` indica il team che deve approvare le modifiche a `config/`, `keys/`, `scripts/`, `server/` e `.github/`.

### 5.5 Impostazioni di Actions

In **Settings → Actions → General**:

- *Workflow permissions*: *Read repository contents*;
- consenti solo azioni di GitHub e verificate;
- richiedi l'approvazione per i workflow delle PR da fork.

Per maggiore sicurezza, fissa `actions/checkout` a uno SHA di commit.

---

## 6. Riferimento della configurazione dichiarativa

I file in `config/` descrivono lo **stato voluto**. `mcp-reconcile` lo confronta con il server ed esegue solo le differenze. Tutto ciò che non è nei file viene riportato a quanto dichiarato: gli utenti non elencati vengono eliminati, e le modifiche manuali ai server gestiti vengono sovrascritte.

### 6.1 `config/servers.yaml`

```yaml
policy:
  max_user_deletions: 3        # l'apply si blocca se eliminerebbe più utenti di così

servers:
  NOME:
    state: present             # present (predefinito) | absent
    install: { ... }           # vedi sotto
    command: ["{dir}/...", "argomento"]
    env:
      VARIABILE: valore
      CREDENZIALE: { secret: NOME_SECRET_GITHUB }
    files:
      nomefile: { secret: NOME_SECRET_GITHUB }
```

| Campo | Significato |
|---|---|
| `state` | `absent` dismette il server: rimuove utente di servizio, gruppo e regola sudo, e conserva la cartella. Prima toglilo a tutti gli utenti |
| `command` | comando che avvia il server MCP in modalità stdio. `{dir}` diventa `/opt/mcp-NOME` |
| `env` | variabili scritte in `/opt/mcp-NOME/NOME.env`. Valori semplici oppure `{ secret: NOME }`, letto dai secret dell'environment `mcp-production` |
| `files` | file creati in `/opt/mcp-NOME` con permessi `640 root:mcp-NOME`, per esempio file di password o certificati |

I valori `true`/`false` e i numeri diventano stringhe (`"true"`, `"8006"`). Per valori come `0` o `yes`, meglio scriverli tra virgolette.

**Metodi di installazione:**

```yaml
# 1) binario scaricato da una release (sha256 obbligatorio)
install:
  method: binary
  url: https://…/nome-binario-linux-amd64
  sha256: "<SHA256>"             # curl -sL <url> | sha256sum
  name: nome-binario             # installato in {dir}/bin/nome-binario
command: ["{dir}/bin/nome-binario", "--transport", "stdio"]

# 2) pacchetto PyPI in un ambiente virtuale dedicato (versione obbligatoria)
install:
  method: pip
  package: nome-pacchetto==<VERSIONE>     # sono ammessi anche gli extra: nome[extra]==<VERSIONE>
  python: "3.13"
command: ["{dir}/venv/bin/nome-comando"]

# 3) nessuna installazione automatica (codice installato a mano in {dir})
install:
  method: none
```

L'installazione viene ripetuta solo quando cambia il blocco `install`. Il codice installato è di proprietà di root, quindi l'utente di servizio non può modificarlo.

### 6.2 `config/users.yaml`

```yaml
users:
  UTENTE:
    servers: [NOME1, NOME2]      # almeno uno, tutti dichiarati in servers.yaml
    expire: 2027-12-31           # facoltativo: dopo questa data la chiave non vale più
    enabled: true                # false = sospeso (l'utente resta, l'accesso no)
    key_file: keys/UTENTE.pub    # facoltativo, questo è il valore predefinito
```

I nomi utente usano minuscole, cifre, `_` e `-`, non possono iniziare con `mcp-` e non devono coincidere con utenti di sistema già esistenti.

### 6.3 `keys/`

Ogni file `UTENTE.pub` contiene **una sola riga**: la chiave pubblica dell'utente, senza opzioni davanti. La chiave privata non entra mai nel repository.

### 6.4 Validazione locale

Prima di aprire una PR puoi validare i file sul tuo PC:

```bash
sudo dnf install -y python3-pyyaml          # oppure: pip install pyyaml
python3 scripts/build_state.py validate
```

L'output indica eventuali errori e l'elenco dei secret richiesti.

---

## 7. Operazioni di amministrazione

### 7.1 Il flusso di una modifica

```
branch da main ─► modifica YAML/chiavi ─► PR ─► piano automatico ─► revisione CODEOWNERS
     ─► merge su main ─► piano ─► ⏸ approvazione ─► apply ─► verifica
```

1. Parti sempre da `main` aggiornato:
   ```bash
   git checkout main && git pull && git checkout -b descrizione-modifica
   ```
2. Modifica i file, poi esegui la validazione locale (paragrafo 6.4).
3. Apri la PR:
   ```bash
   git add … && git commit -m "…" && git push -u origin descrizione-modifica && gh pr create --fill
   ```
4. Leggi il **piano** nel riepilogo del job `plan`. Deve contenere **solo** le modifiche attese:

   ```
   ### Piano MCP — 4 modifiche

   - 🟢 server `NOME`: creazione
   - 🟢 server `NOME`: installazione pacchetto nome-pacchetto==1.2.3 (Python 3.13)
   - 🟢 server `NOME`: configurazione (8 variabili, 0 file)
   - 🟢 utente `UTENTE`: creazione con accesso a NOME
   ```

   Il significato delle icone: 🟢 creazione, 🟡 modifica, 🔴 eliminazione o revoca.
5. Dopo la revisione, fai il merge su `main`.
6. Nel run *MCP · deploy*, il job `apply` attende l'approvazione. Chi approva apre **Actions → run → Review deployments**, seleziona `mcp-production` e clicca **Approve and deploy**.
7. Controlla l'esito nel riepilogo di `apply`: ogni riga deve avere ✅. Al primo errore l'applicazione si interrompe e le operazioni successive non vengono eseguite.

### 7.2 Perché il deploy si fa solo da `main`

La configurazione è dichiarativa: **il branch da cui si fa il deploy diventa la verità**. Un deploy da un branch vecchio annullerebbe le modifiche fatte nel frattempo, con il rischio di eliminare utenti e dismettere server. Per questo il deploy parte solo dal merge su `main`, e l'environment accetta solo `main`.

Se devi sospendere temporaneamente i deploy automatici:

```bash
gh workflow disable "MCP · deploy"      # per riattivarlo: gh workflow enable "MCP · deploy"
```

In alternativa, aggiungi `[skip ci]` al messaggio del commit di merge.

### 7.3 Aggiungere un server MCP

1. **Sul sistema di destinazione**, crea un account dedicato con i permessi minimi, preferibilmente in sola lettura. Consenti le connessioni dal server MCP.
2. **Su GitHub**, crea nell'environment `mcp-production` un secret per ogni credenziale.
3. **Nel repository**, aggiungi il blocco in `config/servers.yaml` (capitolo 6) e autorizza gli utenti in `config/users.yaml`.
4. Segui il flusso del paragrafo 7.1.
5. **Verifica sul server:**
   ```bash
   sudo mcp-admin list
   sudo -u mcp-NOME /opt/mcp-NOME/run.sh
   ```
   Nel secondo comando incolla la riga `initialize` del paragrafo 8.4: deve rispondere con `serverInfo`. Esci con Ctrl+C.
6. Aggiungi la regola auditd per `/opt/mcp-NOME/` (paragrafo 3.2).

Il capitolo 12 contiene esempi completi per Wazuh, UniFi e Proxmox.

### 7.4 Aggiungere un utente

1. L'utente genera la propria chiave e ti manda **solo** il file `.pub` (paragrafo 8.2).
2. Salva la chiave in `keys/UTENTE.pub` e aggiungi la voce in `config/users.yaml`.
3. Segui il flusso del paragrafo 7.1.
4. Manda all'utente l'IP del server, il suo nome utente, i nomi dei server MCP autorizzati e la **fingerprint del server**, che ricavi con:
   ```bash
   sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
   ```

### 7.5 Altre operazioni

| Operazione | Cosa fare |
|---|---|
| Dare o togliere un server a un utente | modifica `servers:` dell'utente |
| Sospendere un utente | `enabled: false` |
| Deprovisioning | rimuovi la voce da `users.yaml` e il file `keys/UTENTE.pub` |
| Chiave nuova (PC cambiato o perso) | sostituisci `keys/UTENTE.pub` |
| Scadenza | aggiungi o modifica `expire` |
| Aggiornare un server MCP | cambia `url` e `sha256`, oppure la versione in `package` |
| Ruotare una credenziale | aggiorna il secret su GitHub, poi **Actions → MCP · deploy → Run workflow** (senza PR) |
| Dismettere un server | toglilo a tutti gli utenti, poi imposta `state: absent` |
| Eliminare molti utenti insieme | alza temporaneamente `policy.max_user_deletions` nella stessa PR |
| Prendere in gestione un server creato a mano | dichiaralo con lo stesso nome: al primo apply compare "presa in gestione" e `run.sh` e `.env` vengono rigenerati |

Ogni sessione attiva di un utente viene chiusa quando gli si revoca un server, gli si cambia la chiave o viene sospeso o eliminato.

### 7.6 Emergenze

Se una chiave è compromessa o un utente va bloccato subito, intervieni direttamente sul server:

```bash
sudo mcp-admin user-lock UTENTE
```

Subito dopo apri la PR (`enabled: false` o rimozione dell'utente). Senza la PR, il deploy successivo riattiverebbe l'utente.

Per le credenziali di un sistema, revocale **sul sistema** (token, password), poi aggiorna il secret ed esegui il deploy.

### 7.7 Controllo del drift

Il workflow *MCP · validazione e piano* gira anche ogni notte. Se il piano notturno mostra modifiche senza che ci siano PR, qualcuno ha cambiato il server a mano. Individua chi con i log (capitolo 10) e decidi se riportare la modifica nei file YAML o lasciarla annullare dal deploy successivo.

---

## 8. Guida per l'utente finale

Questo capitolo si può consegnare così com'è a chi deve usare la piattaforma.

### 8.1 Installare Claude Code

Su Linux e macOS usa l'installer nativo, che non richiede Node.js né permessi di amministratore:

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

Apri un nuovo terminale e verifica:

```bash
which claude        # ~/.local/bin/claude
claude --version
claude              # primo avvio: login nel browser
```

Per Windows e per altri metodi di installazione, consulta la documentazione di Claude Code.

### 8.2 Generare la propria chiave SSH

Su Linux o macOS:

```bash
ssh-keygen -t ed25519 -C "UTENTE@mcp" -f ~/.ssh/mcp_UTENTE
cat ~/.ssh/mcp_UTENTE.pub
```

Su Windows (PowerShell):

```powershell
ssh-keygen -t ed25519 -C "UTENTE@mcp" -f $env:USERPROFILE\.ssh\mcp_UTENTE
Get-Content $env:USERPROFILE\.ssh\mcp_UTENTE.pub
```

Lascia la passphrase **vuota**: Claude Code usa SSH senza interazione. In alternativa puoi impostarla e caricare la chiave in `ssh-agent` prima di avviare Claude Code.

Invia all'amministratore **solo** la riga del file `.pub`. Il file senza estensione è la chiave privata e non deve mai lasciare il tuo PC.

### 8.3 Configurare SSH

Aggiungi al file `~/.ssh/config` i dati ricevuti dall'amministratore:

```
Host mcp
    HostName IP-SERVER-MCP
    User UTENTE
    IdentityFile ~/.ssh/mcp_UTENTE
    IdentitiesOnly yes
    BatchMode yes
    ConnectTimeout 10
```

### 8.4 Primo collegamento e registrazione

Per il primo collegamento, che serve ad accettare la fingerprint del server:

```bash
ssh -o BatchMode=no -T mcp NOME
```

Confronta la fingerprint con quella ricevuta dall'amministratore e rispondi `yes`. Se il comando resta in attesa senza errori, l'accesso funziona: esci con Ctrl+C.

Per una verifica completa, mentre il comando è in attesa incolla questa riga e premi Invio:

```json
{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}
```

La risposta deve contenere `serverInfo`.

Registra poi ogni server MCP autorizzato in Claude Code:

```bash
claude mcp add --scope user NOME -- ssh -T mcp NOME
claude mcp list
```

In Claude Code, il comando `/mcp` mostra lo stato delle connessioni. L'ultimo argomento (`NOME`) è il nome del server MCP richiesto al gateway: non servono percorsi né comandi.

### 8.5 Messaggi che puoi incontrare

| Messaggio | Significato |
|---|---|
| `Accesso interattivo non consentito` | hai aperto SSH senza indicare il server MCP: è normale, l'accesso alla shell non è previsto |
| `Non sei autorizzato al server MCP 'NOME'` | chiedi all'amministratore di abilitarti |
| `Permission denied (publickey)` | chiave sbagliata, account sospeso o chiave scaduta |
| `connection timed out after 30000ms` | vedi il capitolo 11 |

### 8.6 Rimuovere un server da Claude Code

```bash
claude mcp list
claude mcp remove NOME --scope user
```

---

## 9. Gestione manuale con mcp-admin

`mcp-admin` è lo strumento che la pipeline usa dietro le quinte. Si usa direttamente in tre casi: per **consultare** lo stato, per le **emergenze** e sulle installazioni **senza pipeline**.

> Con la pipeline attiva, le modifiche fatte a mano con `mcp-admin` su server e utenti dichiarati nei YAML vengono annullate al deploy successivo.

### 9.1 Comandi

| Comando | Funzione |
|---|---|
| `mcp-admin setup` | configurazione iniziale (gruppo `mcp-users`, gateway, blocco sshd) |
| `mcp-admin server-add NOME` | crea utente di servizio, cartella, gruppo e regola sudo |
| `mcp-admin server-del NOME` | rimuove regola sudo, gruppo e utente di servizio, e conserva la cartella |
| `mcp-admin user-add UTENTE --servers a,b [--pubkey FILE] [--expire AAAAMMGG]` | crea un utente |
| `mcp-admin user-grant UTENTE NOME` / `user-revoke UTENTE NOME` | autorizza o revoca un server MCP |
| `mcp-admin user-rotate-key UTENTE [--pubkey FILE] [--expire AAAAMMGG]` | sostituisce la chiave |
| `mcp-admin user-lock UTENTE` / `user-unlock UTENTE` | sospende o riattiva l'accesso |
| `mcp-admin user-del UTENTE` | elimina l'utente |
| `mcp-admin list` | mostra server, utenti, autorizzazioni, stato e scadenza delle chiavi |

Per indicare nelle istruzioni stampate l'IP del server invece del nome host, avvia i comandi con `sudo MCP_SERVER_HOST=IP-SERVER-MCP mcp-admin …`.

### 9.2 Installazione senza pipeline

1. Installa lo script ed esegui il setup:
   ```bash
   sudo install -m 700 -o root -g root mcp-admin /usr/local/sbin/mcp-admin
   sudo mcp-admin setup
   ```
2. Crea il server MCP:
   ```bash
   sudo mcp-admin server-add NOME
   ```
3. Installa il codice in `/opt/mcp-NOME`. Metti le credenziali in `/opt/mcp-NOME/NOME.env`, con proprietario `mcp-NOME` e permessi `600`. Completa `/opt/mcp-NOME/run.sh`, che viene creato come modello:
   ```bash
   #!/bin/bash
   set -a
   source /opt/mcp-NOME/NOME.env
   set +a
   exec /opt/mcp-NOME/venv/bin/nome-comando
   ```
4. Prova il server:
   ```bash
   sudo -u mcp-NOME /opt/mcp-NOME/run.sh
   ```
5. Crea l'utente:
   ```bash
   sudo mcp-admin user-add UTENTE --servers NOME --pubkey /tmp/UTENTE.pub
   ```

Senza `--pubkey`, `user-add` genera una chiave ed25519 in memoria (`/dev/shm`) e la mostra **una sola volta** a terminale, con i comandi `claude mcp add` già pronti, poi la distrugge. Trasmettila all'utente su un canale sicuro e cancella lo scrollback del terminale. Quando possibile, però, preferisci la chiave generata dall'utente.

---

## 10. Monitoraggio, audit e verifiche di sicurezza

### 10.1 Registri

```bash
journalctl -t mcp-gateway --since today       # chi ha usato quale server MCP, tentativi negati
journalctl -t mcp-reconcile --since today     # esiti degli apply
journalctl _COMM=sudo --since today           # esecuzioni di run.sh e reconcile
journalctl -u sshd --since today              # accessi SSH (Debian/Ubuntu: -u ssh)
sudo ausearch -k mcp-keys -i                  # modifiche alle chiavi degli utenti
sudo ausearch -k mcp-sudoers -i               # modifiche alle regole sudo
```

Voci tipiche del gateway:

```
mcp-gateway: ALLOW user=alice from=192.168.10.20 server=wazuh
mcp-gateway: DENY user=bob from=192.168.10.31 server=proxmox reason=not-authorized
```

Su GitHub, la cronologia dei commit, le PR, le approvazioni degli environment e i riepiloghi dei job documentano **chi** ha cambiato **cosa** e **chi** l'ha approvato.

### 10.2 Verifiche periodiche

Dal PC di un utente, questi tentativi **devono fallire**:

```bash
ssh mcp                                  # "Accesso interattivo non consentito"
ssh mcp 'NOME; id'                       # "Nome del server MCP non valido"
ssh mcp NOME-NON-AUTORIZZATO             # "Non sei autorizzato…"
ssh -N -L 8080:127.0.0.1:22 mcp          # port forwarding rifiutato
```

Sul server MCP:

```bash
# un utente non può leggere le credenziali
sudo -u UTENTE cat /opt/mcp-NOME/NOME.env                    # Permission denied

# configurazione sshd effettiva per un utente e per la pipeline
sudo sshd -T -C user=UTENTE,host=client,addr=IP-CLIENT | grep -Ei 'forcecommand|disableforwarding|permittty'
sudo sshd -T -C user=mcp-deploy,host=runner,addr=IP-RUNNER | grep -Ei 'authorizedkeysfile|permittty'

# stato generale
sudo mcp-admin list
```

Una volta al mese conviene anche:

- controllare in `mcp-admin list` le chiavi **scadute** o in scadenza;
- verificare che gli account sui sistemi di destinazione abbiano ancora i soli permessi previsti;
- ruotare le credenziali secondo la politica aziendale (paragrafo 7.5).

---

## 11. Risoluzione dei problemi

### 11.1 Client e Claude Code

| Sintomo | Causa e soluzione |
|---|---|
| `npm error code EACCES` installando Claude Code | npm prova a scrivere in `/usr/local`. Non usare `sudo npm`: usa l'installer nativo (paragrafo 8.1). Per rimuovere la vecchia installazione: `npm uninstall -g @anthropic-ai/claude-code` |
| `claude: File o directory non esistente` dopo aver cambiato metodo di installazione | bash ricorda il vecchio percorso: esegui `hash -r` o apri un nuovo terminale |
| `connection timed out after 30000ms` | SSH attende un input che Claude Code non può dare. Esegui `ssh -o BatchMode=yes -T mcp NOME` e leggi l'errore |
| `Host key verification failed` | primo collegamento mai fatto: esegui `ssh -o BatchMode=no -T mcp NOME` e accetta la fingerprint |
| `Permission denied (publickey)` | chiave errata o permessi sbagliati (`chmod 600 ~/.ssh/mcp_UTENTE`), utente sospeso o chiave scaduta: controlla con `sudo mcp-admin list` |
| `Server MCP 'NOME' non ancora configurato` | `run.sh` è ancora il modello: completa la configurazione del server |
| Il server parte ma gli strumenti restituiscono errori | problema tra server MCP e sistema di destinazione: prova `sudo -u mcp-NOME /opt/mcp-NOME/run.sh` sul server e controlla rete, credenziali e certificati |

Per i dettagli della connessione MCP avvia Claude Code con `claude --debug`. Per allungare il tempo di attesa: `MCP_TIMEOUT=60000 claude`.

### 11.2 Pipeline

| Messaggio nel job | Causa e soluzione |
|---|---|
| `MCP_SSH_KEY mancante` | manca il secret `MCP_PLAN_SSH_KEY` a livello di **repository** (spesso è stato creato nell'environment), oppure la PR arriva da un fork. Per `apply`, manca `MCP_APPLY_SSH_KEY` nell'environment |
| `MCP_SSH_KNOWN_HOSTS mancante` / `MCP_SERVER_HOST mancante` | mancano le **variabili** del repository (scheda *Variables*, non *Secrets*) |
| `Host key verification failed` | la riga known_hosts non corrisponde: il nome iniziale deve essere identico a `MCP_SERVER_HOST`. Rigenera la riga con `ssh-keyscan` |
| `Permission denied (publickey)` | IP del runner non incluso in `--from` (runner sulla stessa macchina: aggiungi l'IP del server e `127.0.0.1`), oppure chiave diversa da quella installata. Riesegui `install-deploy.sh` |
| `Errori nella configurazione: …` | errore nei YAML o nelle chiavi: il messaggio indica file e campo |
| `secret mancanti nell'environment GitHub: …` | crea i secret indicati in `mcp-production` |
| `mcp-admin setup non eseguito sul server` | esegui `install-deploy.sh` (capitolo 3) |
| `sha256 non corrispondente` | lo sha256 nel YAML non corrisponde al file scaricato: ricalcolalo con `curl -sL URL \| sha256sum` e verifica la fonte |
| `/usr/local/bin/uv non trovato` | installa `uv` (paragrafo 3.1) |
| `il piano elimina N utenti (limite …)` | l'eliminazione è voluta? Alza `policy.max_user_deletions` nella stessa PR |
| `l'utente di sistema 'X' esiste ma non è un utente MCP` | scegli un altro nome utente |
| `un'altra esecuzione di mcp-reconcile è in corso` | attendi la fine dell'altra esecuzione e rilancia |
| Il job `apply` resta in attesa | serve l'approvazione: **Review deployments** |
| Il job `apply` viene rifiutato per il branch | l'environment accetta solo `main`: fai il deploy dal merge |
| Il runner non prende i job | etichette diverse da quelle nel workflow (`mcp-plan`, `mcp-apply`), oppure runner offline: `sudo ./svc.sh status` |
| Il servizio del runner fallisce con `203/EXEC` | SELinux: applica `semanage` e `restorecon` (paragrafo 4.3) |
| `gh: comando non trovato` | installa `gh` sulla postazione di amministrazione (`sudo dnf install gh`, poi `gh auth login`) |

Per rilanciare un job fallito: pagina del run → **Re-run jobs → Re-run failed jobs**.

### 11.3 Server MCP

| Sintomo | Causa e soluzione |
|---|---|
| `Connection timed out` dal server MCP verso un sistema | firewall sul sistema di destinazione o in mezzo |
| `Connection refused` | il servizio ascolta solo in locale sul sistema di destinazione |
| Errori TLS | certificato autofirmato: imposta la variabile di verifica SSL del server MCP, oppure aggiungi la CA del sistema a quelle attendibili del server MCP |
| `sshd -t` fallisce dopo una modifica | gli script annullano da soli le proprie modifiche; per quelle manuali correggi il file indicato prima di ricaricare |

---

## 12. Configurazione dei server MCP: Wazuh, UniFi, Proxmox

Questo capitolo applica la procedura del paragrafo 7.3 a tre sistemi concreti. Ogni sezione descrive gli stessi quattro passaggi: account sul sistema, rete, secret su GitHub e blocco da inserire in `config/servers.yaml`.

| Server MCP | Progetto | Installazione | Accesso |
|---|---|---|---|
| `wazuh` | [gbrigandi/mcp-server-wazuh](https://github.com/gbrigandi/mcp-server-wazuh) | binario (Rust) | API del manager + Indexer, sola lettura |
| `unifi` | [sirkirby/unifi-mcp](https://github.com/sirkirby/unifi-mcp), pacchetto `unifi-network-mcp` | pip | amministratore locale *View Only* |
| `proxmox` | [GethosTheWalrus/proxmox-mcp](https://github.com/GethosTheWalrus/proxmox-mcp), pacchetto `proxmox-mcp-server` | pip | API token con ruolo `PVEAuditor` e modalità sola lettura |

Prima di ogni installazione controlla l'ultima versione disponibile di ciascun progetto e fissala nel YAML.

### 12.1 Wazuh

#### Account API del manager

Nella dashboard di Wazuh vai su **Server management → Security → Users**. Crea l'utente `mcp_readonly` e assegnagli il ruolo **`readonly`**.

#### Account dell'Indexer

L'Indexer è basato su OpenSearch: servono un **ruolo**, un **utente interno** e una **mappatura** tra i due.

Per crearli dalla dashboard, apri **☰ → Indexer management → Security** (nelle versioni meno recenti *OpenSearch Plugins → Security*) e procedi così:

1. **Roles → Create role**, con nome `mcp_alerts_readonly`:
   - *Cluster permissions*: `cluster_composite_ops_ro`;
   - *Index*: `wazuh-alerts-*`, `wazuh-states-vulnerabilities-*`;
   - *Index permissions*: `read`.
2. **Internal users → Create internal user**, con nome `mcp_indexer`, senza backend roles.
3. Nel ruolo `mcp_alerts_readonly` apri **Mapped users → Manage mapping** e aggiungi `mcp_indexer`.

In alternativa, dalla riga di comando della macchina Wazuh:

```bash
read -s -p "Password admin indexer: " ADMIN_PW; echo
read -s -p "Nuova password per mcp_indexer: " MCP_PW; echo
IDX=https://localhost:9200

curl -k -u "admin:$ADMIN_PW" -X PUT "$IDX/_plugins/_security/api/roles/mcp_alerts_readonly" \
  -H 'Content-Type: application/json' -d '{
  "cluster_permissions": ["cluster_composite_ops_ro"],
  "index_permissions": [{
    "index_patterns": ["wazuh-alerts-*", "wazuh-states-vulnerabilities-*"],
    "allowed_actions": ["read"]
  }]
}'
curl -k -u "admin:$ADMIN_PW" -X PUT "$IDX/_plugins/_security/api/internalusers/mcp_indexer" \
  -H 'Content-Type: application/json' -d "{\"password\": \"$MCP_PW\"}"
curl -k -u "admin:$ADMIN_PW" -X PUT "$IDX/_plugins/_security/api/rolesmapping/mcp_alerts_readonly" \
  -H 'Content-Type: application/json' -d '{"users": ["mcp_indexer"]}'
```

Per verificare, la lettura deve **riuscire** e le scritture devono fallire con **403**:

```bash
curl -k -u "mcp_indexer:$MCP_PW" "$IDX/wazuh-alerts-*/_search?size=1&pretty"   # OK
curl -k -u "mcp_indexer:$MCP_PW" -X PUT "$IDX/test-mcp"                         # 403
unset ADMIN_PW MCP_PW
```

L'indice `wazuh-states-vulnerabilities-*` esiste da Wazuh 4.8 in poi.

#### Rete

Il server MCP deve raggiungere l'API del manager (**55000**) e l'Indexer (**9200**).

Sulla macchina Wazuh, controlla che i servizi ascoltino sulla rete e non solo in locale:

```bash
sudo ss -tlnp | grep -E '55000|9200'
```

Se vedi `127.0.0.1:9200`, imposta `network.host` in `/etc/wazuh-indexer/opensearch.yml` con l'IP della macchina, coerente con i certificati dell'Indexer, poi riavvia `wazuh-indexer`.

Apri le porte solo verso il server MCP:

```bash
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="IP-SERVER-MCP" port port="55000" protocol="tcp" accept'
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="IP-SERVER-MCP" port port="9200" protocol="tcp" accept'
sudo firewall-cmd --reload
```

Dal server MCP verifica la connessione:

```bash
curl -k -u mcp_readonly:PASSWORD -X POST "https://IP-WAZUH:55000/security/user/authenticate?raw=true"   # token JWT
curl -k -u mcp_indexer:PASSWORD "https://IP-WAZUH:9200/wazuh-alerts-*/_search?size=1&pretty"          # un alert
```

#### Secret (environment `mcp-production`)

`WAZUH_API_USERNAME`, `WAZUH_API_PASSWORD`, `WAZUH_INDEXER_USERNAME`, `WAZUH_INDEXER_PASSWORD`.

#### Configurazione

```yaml
  wazuh:
    install:
      method: binary
      url: https://github.com/gbrigandi/mcp-server-wazuh/releases/download/<VERSIONE>/mcp-server-wazuh-linux-amd64
      sha256: "<SHA256>"
      name: mcp-server-wazuh
    command: ["{dir}/bin/mcp-server-wazuh", "--transport", "stdio"]
    env:
      WAZUH_API_HOST: IP-WAZUH
      WAZUH_API_PORT: 55000
      WAZUH_API_USERNAME: { secret: WAZUH_API_USERNAME }
      WAZUH_API_PASSWORD: { secret: WAZUH_API_PASSWORD }
      WAZUH_INDEXER_HOST: IP-WAZUH
      WAZUH_INDEXER_PORT: 9200
      WAZUH_INDEXER_USERNAME: { secret: WAZUH_INDEXER_USERNAME }
      WAZUH_INDEXER_PASSWORD: { secret: WAZUH_INDEXER_PASSWORD }
      WAZUH_VERIFY_SSL: "false"
      RUST_LOG: warn
```

Scegli la release dalla pagina *Releases* del progetto e calcola lo sha256 con `curl -sL URL | sha256sum`. Se Wazuh gira sullo stesso host del server MCP, usa `localhost`.

`WAZUH_VERIFY_SSL: "false"` disattiva il controllo dei certificati. Per attivarlo, aggiungi il `root-ca.pem` di Wazuh alle CA del server MCP e imposta `"true"`.

Esempi di richieste da provare in Claude Code: *"mostrami gli ultimi alert critici"*, *"quali agenti sono disconnessi?"*, *"vulnerabilità critiche dell'agente X"*.

### 12.2 UniFi (UDM Pro)

#### Account

Nella console UniFi, in **Admins & Users**, crea un **amministratore locale** `mcp_viewer` con ruolo **View Only** per Network. Non usare un account Ubiquiti SSO cloud. Il server MCP non supporta account con **MFA/2FA**, quindi questo account dedicato deve esserne privo: compensa con password lunga, permessi minimi e accesso consentito solo dal server MCP.

#### Rete

Il server MCP deve raggiungere il UDM Pro sulla porta **443**:

```bash
curl -k -I https://IP-UDM
```

Se il server MCP è in un'altra VLAN, verifica le regole firewall del UDM.

#### Secret (environment `mcp-production`)

`UNIFI_USERNAME`, `UNIFI_PASSWORD`.

#### Configurazione

```yaml
  unifi:
    install:
      method: pip
      package: unifi-network-mcp==<VERSIONE>
      python: "3.13"
    command: ["{dir}/venv/bin/unifi-network-mcp"]
    env:
      UNIFI_HOST: IP-UDM
      UNIFI_USERNAME: { secret: UNIFI_USERNAME }
      UNIFI_PASSWORD_FILE: "{dir}/password"
      UNIFI_VERIFY_SSL: "false"
    files:
      password: { secret: UNIFI_PASSWORD }
```

La password viene scritta in un file (`640 root:mcp-unifi`) invece che in una variabile d'ambiente. Il server MCP la legge tramite `UNIFI_PASSWORD_FILE`. `UNIFI_VERIFY_SSL: "false"` serve per il certificato autofirmato del UDM.

Il progetto nasconde di default i segreti nelle risposte (password Wi-Fi, chiavi VPN), e ogni modifica passa da un'anteprima con conferma. Con un account *View Only*, però, le modifiche sono comunque bloccate alla fonte.

Esempi di richieste: *"mostrami i client connessi sulla VLAN ospiti"*, *"fai un audit delle regole firewall"*.

### 12.3 Proxmox VE

#### Account e token

Sul nodo Proxmox, come root:

```bash
pveum user add mcp@pve --comment "Server MCP (sola lettura)"
pveum acl modify / --users mcp@pve --roles PVEAuditor
pveum user token add mcp@pve mcp --privsep 1
pveum acl modify / --tokens 'mcp@pve!mcp' --roles PVEAuditor
```

Il valore del token viene mostrato **una sola volta**. Con `--privsep 1` il token ha permessi propri, per questo serve la seconda ACL. La protezione è su tre livelli: il ruolo `PVEAuditor`, la modalità sola lettura del server MCP e la chiamata API generica disattivata.

#### Rete

Il server MCP deve raggiungere l'API di Proxmox sulla porta **8006**. Se il firewall del datacenter è attivo, consenti la porta dall'IP del server MCP.

#### Secret (environment `mcp-production`)

```bash
gh secret set PROXMOX_USER --env mcp-production --body "mcp@pve"
gh secret set PROXMOX_TOKEN_NAME --env mcp-production --body "mcp"
gh secret set PROXMOX_TOKEN_VALUE --env mcp-production
```

#### Configurazione

```yaml
  proxmox:
    install:
      method: pip
      package: proxmox-mcp-server==<VERSIONE>
      python: "3.13"
    command: ["{dir}/venv/bin/proxmox-mcp-server"]
    env:
      PROXMOX_HOST: IP-PROXMOX
      PROXMOX_PORT: 8006
      PROXMOX_USER: { secret: PROXMOX_USER }
      PROXMOX_TOKEN_NAME: { secret: PROXMOX_TOKEN_NAME }
      PROXMOX_TOKEN_VALUE: { secret: PROXMOX_TOKEN_VALUE }
      PROXMOX_VERIFY_SSL: "0"
      PROXMOX_READ_ONLY: "true"
      PROXMOX_DISABLE_RAW_API: "true"
```

Con `PROXMOX_READ_ONLY` sono consentite solo chiamate GET. Con `PROXMOX_DISABLE_RAW_API` viene disattivato lo strumento di chiamata API arbitraria.

Il server espone diverse centinaia di strumenti. Se occupano troppo contesto in Claude Code, attiva l'instradamento semantico: usa `package: proxmox-mcp-server[router]==<VERSIONE>` e aggiungi `TOOL_ROUTING: "true"`. Il client vedrà solo pochi strumenti, che caricano gli altri su richiesta.

**Rotazione del token:**

1. crea un nuovo token con la sua ACL;
2. aggiorna `PROXMOX_TOKEN_NAME` e `PROXMOX_TOKEN_VALUE`;
3. esegui **Run workflow** su *MCP · deploy* e approva;
4. elimina il vecchio token con `pveum user token remove mcp@pve NOME_VECCHIO`.

Esempi di richieste: *"elenca VM e container con il loro stato"*, *"quanto spazio resta sugli storage?"*, *"quali backup sono falliti questa settimana?"*.

### 12.4 Esempio completo di `users.yaml`

```yaml
users:
  alice:
    servers: [wazuh, unifi]
    expire: 2027-12-31
  bob:
    servers: [wazuh]
  giorgio:
    servers: [proxmox]
```

---

## Appendice A — Codice sorgente

Questo è il codice dei file del repository di configurazione. I file `config/servers.yaml` e `config/users.yaml` sono descritti nei capitoli 6 e 12.

### A.1 mcp-admin

`server/mcp-admin` — installato in `/usr/local/sbin/mcp-admin`. Il gateway `/usr/local/bin/mcp-gateway` è generato da `mcp-admin setup`

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

### A.2 mcp-reconcile

`server/mcp-reconcile` — installato in `/usr/local/sbin/mcp-reconcile`

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

### A.3 install-deploy.sh

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

### A.4 build_state.py

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

### A.5 ssh_run.sh

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

### A.6 Workflow di validazione e piano

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

### A.7 Workflow di deploy

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

### A.8 CODEOWNERS

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

---

## Appendice B — Evoluzione: segreti in HashiCorp Vault

> Questa appendice descrive un'evoluzione **non ancora implementata** negli script dell'Appendice A.

Oggi le credenziali dei sistemi stanno nei secret dell'environment GitHub `mcp-production`. Per centralizzarle in un gestore di segreti interno puoi usare **Vault Community** oppure **OpenBao**, il fork open source della Linux Foundation: le API sono compatibili. HCP Vault Secrets, la versione SaaS semplificata, è stata dismessa nel 2026. Il gestore va installato nella rete interna, su una macchina dedicata, con TLS, audit attivo e backup.

### Organizzazione dei segreti

Si usa un motore KV v2 (`mcp/`) con un percorso per ogni server MCP. KV v2 conserva lo storico delle versioni.

```
mcp/
├── wazuh     → api_username, api_password, indexer_username, indexer_password
├── unifi     → username, password
└── proxmox   → user, token_name, token_value
```

```bash
vault secrets enable -path=mcp kv-v2
vault kv put mcp/proxmox user=mcp@pve token_name=mcp token_value=-     # il valore viene letto da stdin
vault kv get mcp/proxmox
vault kv rollback -version=2 mcp/proxmox
```

Servono due policy: `mcp-admin` per le persone che gestiscono i segreti (`create`, `update`, `read` su `mcp/data/*`) e `mcp-deploy` per la pipeline (solo `read` su `mcp/data/*`).

### Integrazione possibile

Nei YAML, i riferimenti diventerebbero `{ vault: "percorso#campo" }`, per esempio `PROXMOX_TOKEN_VALUE: { vault: "proxmox#token_value" }`. Esistono due modelli di integrazione:

| | A — Vault letto dalla pipeline | B — Vault letto dal server MCP a ogni avvio |
|---|---|---|
| Come | il job `apply` si autentica a Vault con il token OIDC di GitHub, vincolato a repository, environment e `main` | ogni server MCP ha un'identità AppRole che può leggere solo il proprio percorso; `run.sh` legge le credenziali all'avvio |
| Credenziali su GitHub | nessuna | nessuna |
| Credenziali su disco nel server MCP | sì (`640`) | no |
| Rotazione | Vault + deploy | solo Vault |
| Se Vault non risponde | niente deploy | i server MCP non partono |
| Modifiche | `build_state.py` e workflow | `mcp-reconcile`, `run.sh`, distribuzione delle identità AppRole |

Wazuh, UniFi e Proxmox non hanno motori di credenziali dinamiche in Vault: in entrambi i modelli si usano segreti statici, ruotati a mano o con script.

---

## Riferimenti

- Claude Code — server MCP: <https://docs.claude.com/en/docs/claude-code/mcp>
- Model Context Protocol: <https://modelcontextprotocol.io>
- GitHub Actions — environment e approvazioni: <https://docs.github.com/actions/deployment/targeting-different-environments/using-environments-for-deployment>
- GitHub Actions — runner self-hosted: <https://docs.github.com/actions/hosting-your-own-runners>
- Server MCP Wazuh: <https://github.com/gbrigandi/mcp-server-wazuh>
- Server MCP UniFi: <https://github.com/sirkirby/unifi-mcp>
- Server MCP Proxmox: <https://github.com/GethosTheWalrus/proxmox-mcp>
- uv: <https://docs.astral.sh/uv/>
- OpenBao: <https://openbao.org>
