# Jarvis infra

Servizi Docker di Jarvis. Segreti in `.env` (mai in Git, mai nel vault).

| Servizio | URL | Note |
|---|---|---|
| LiteLLM (Model Gateway) | http://localhost:4000 | API compatibile OpenAI |
| LiteLLM UI | http://localhost:4000/ui | utente `admin`, password = LITELLM_MASTER_KEY |

Comandi: `docker compose up -d` · `docker compose ps` · `docker compose logs -f litellm` · `docker compose down`
Test: `.\test.ps1`

Prossimi: Langfuse (tracing), n8n (automazioni).
