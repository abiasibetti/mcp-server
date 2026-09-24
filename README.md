# mcp-infra

Configurazione dichiarativa dei server MCP interni e dei relativi utenti.

| Cartella | Contenuto |
|---|---|
| `config/servers.yaml` | Server MCP: installazione, comando, variabili (i segreti sono riferimenti ai secret GitHub) |
| `config/users.yaml` | Utenti, server autorizzati, scadenze, sospensioni |
| `keys/` | Chiavi pubbliche SSH degli utenti (`NOME.pub`) |
| `scripts/` | Script eseguiti dalla pipeline |
| `server/` | Script da installare sul server MCP (`mcp-admin`, `mcp-reconcile`) |
| `.github/workflows/` | Pipeline di piano e deploy |

Flusso: pull request → validazione e piano → revisione → merge su `main` → piano →
**approvazione** (environment `mcp-production`) → applicazione.

La guida completa è nel documento "Server MCP interno per Wazuh e UniFi", sezione 12.
