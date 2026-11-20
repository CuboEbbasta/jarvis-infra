# Profili social di Brina

Un file `.yml` per profilo (azienda, creator, clipping, progetti). La pagina **Social** dell'app li legge in sola lettura.

```yaml
versione: 1
id: clip-gta6-tiktok        # minuscole, cifre e trattini (max 40): e' anche il nome del file delle metriche
nome: "Clip GTA 6"
piattaforma: tiktok         # youtube | tiktok | instagram | twitch | x | linkedin | facebook | altro
gruppo: clipping            # azienda | creator | clipping | progetto | personale
handle: "@nomeprofilo"      # facoltativo
url: https://www.tiktok.com/@nomeprofilo   # facoltativo, solo https
progetto: clipgta6          # facoltativo
```

Le metriche stanno nel vault, `DBVault/Machine/Social/<id>.csv`, una riga per giorno:

```
data,follower,visualizzazioni,contenuti,interazioni
2026-11-20,1250,48000,31,2200
```

Le celle vuote sono ammesse. Finché il file non esiste il profilo compare come «da collegare» (nessun numero inventato).
Le API dei social non sono collegate: i numeri li scrive un agente o li aggiorni a mano.
