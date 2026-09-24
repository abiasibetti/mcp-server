# Chiavi pubbliche degli utenti MCP

Un file per utente: `NOME.pub`, contenente **una sola riga** con la chiave pubblica,
senza opzioni davanti (niente `command=`, `from=`...).

L'utente la genera sul proprio PC e invia solo il file `.pub`:

```bash
ssh-keygen -t ed25519 -C "nome@mcp" -f ~/.ssh/mcp_nome
cat ~/.ssh/mcp_nome.pub
```
