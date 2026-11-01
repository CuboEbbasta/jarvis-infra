# Test del Model Gateway: chiede una risposta a local-fast tramite LiteLLM
$key = (Get-Content "$PSScriptRoot\.env" | Where-Object { $_ -match '^LITELLM_MASTER_KEY=' }) -replace '^LITELLM_MASTER_KEY=',''
$body = @{
  model    = "local-fast"
  messages = @(@{ role = "user"; content = "Rispondi solo con: Jarvis gateway operativo" })
} | ConvertTo-Json -Depth 5
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Invoke-RestMethod -Uri "http://localhost:4000/v1/chat/completions" -Method Post `
     -Headers @{ Authorization = "Bearer $key" } -ContentType "application/json; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($body))
$sw.Stop()
"Modello : $($r.model)"
"Risposta: $($r.choices[0].message.content)"
"Token   : $($r.usage.total_tokens)   Tempo: $([math]::Round($sw.Elapsed.TotalSeconds,1)) s"
