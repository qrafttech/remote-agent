# orca-host — inventaire de la VM

Tout ce qui a été fait pour que `orca-host` tourne, dans l'ordre, avec qui l'a fait (script ou main) et sur quelle machine.
Objectif : que **tout ce qui est « main » ci-dessous devienne script**, et que rien ne dépende du laptop.
Contexte : epistofr/episto#2063.

## État (2026-09-21)

| | |
|---|---|
| VM | `orca-host`, GCP `qraft-remote-agent-nrouanne`, `europe-west9-b`, e2-standard-4, 100 Go pd-balanced, Debian 12 |
| IP publique | 34.155.16.240 — seul 22 ouvert (firewall GCP par défaut) |
| Tailnet Qraft | `orca-host` = `100.105.104.105` (compte nicolas.rouanne@qraft.tech) |
| Orca | 1.4.205, `orca serve` sur `100.105.104.105:6768`, unit systemd `orca-serve`, user `orca` |
| Claude Code | 2.1.276 dans `/home/orca/.local/bin`, loggué (abonnement, `~/.claude/.credentials.json`) |
| Projet | `/home/orca/episto` (clone SSH, `gh` loggué nicolasrouanne), enregistré dans Orca (repo `58f5ce25-…`) |
| Worktrees | `/home/orca/orca/workspaces/episto/<branche>` |
| Client | Orca desktop du laptop, environnement `orca-host` (`a0da68ab-…`), serveur actif |
| Mono-utilisateur | un seul user système `orca` : login Claude, `gh`, identité git et `.env` sont ceux de Nicolas |

## 1. Créer la VM — laptop, main

```bash
gcloud compute instances create orca-host --project qraft-remote-agent-nrouanne --zone europe-west9-b \
  --machine-type e2-standard-4 --image-family debian-12 --image-project debian-cloud \
  --boot-disk-size 100GB --boot-disk-type pd-balanced
```

Refaire à neuf = `gcloud compute instances delete orca-host …` puis la même commande.

## 2. Système — VM, root, **script** `install.sh`

`gcloud compute scp install.sh orca-host:~ && gcloud compute ssh orca-host -- sudo bash install.sh`. Idempotent. Il fait :

1. apt : deps Electron/Xvfb (doc headless Orca), `git jq curl lsof make file`
2. Docker (`get.docker.com`, Compose ≥ 2.24 — requis par `bin/worktree`)
3. `gh`
4. Tailscale, `tailscale up --hostname orca-host` — **main** : sans `TS_AUTHKEY`, le script imprime l'URL, on approuve la machine dans l'admin Tailscale, on relance
5. Orca AppImage 1.4.205 extraite dans `/opt/orca/squashfs-root` (pas de FUSE), wrapper `/usr/local/bin/orca` avec `LIBGL_ALWAYS_SOFTWARE=1`
6. user `orca` (bash, groupe `docker`), Claude Code 2.1.276 dans son `~/.local/bin` (installeur natif)
7. unit `orca-serve` : `AppRun serve --port 6768 --pairing-address <IP tailnet>`, `Restart=on-failure`, enabled
8. rapport + commande pour lire l'URL de pairing dans le journal

## 3. Appairage — laptop, main

```bash
# sur la VM : l'URL de pairing
sudo journalctl -u orca-serve -o cat | grep '^Pairing URL:' | tail -1
# sur le laptop (Orca desktop installé, laptop sur le tailnet)
orca environment add --name orca-host --pairing-code '<URL>'
orca status --environment orca-host     # runtimeConnectionState: connected, graphState: ready
```

Puis dans l'app : Settings → Remote Orca Servers → Advanced → **Active Server = orca-host**. L'appairage survit aux redémarrages du service.

## 4. Projet — VM, user `orca`, main (dans un terminal Orca, qui tourne sur la VM)

```bash
gh auth login                        # GitHub, SSH, navigateur
git clone git@github.com:epistofr/episto.git ~/episto
git config --global user.name  "Nicolas Rouanne"
git config --global user.email nicolas.rouanne@qraft.tech
# api/.env et chat/.env copiés depuis le laptop dans ~/episto (1Password : « DEV webapp .env », « DEV chat .env »)
cd ~/episto && docker build -t base-episto-ruby -f api/docker/app/Dockerfile.base api   # 810 Mo, ~5 min
```

Puis depuis le laptop : `orca repo add --environment orca-host --path /home/orca/episto` (il faut un vrai dépôt git, pas un dossier vide).

## 5. Login Claude — VM, user `orca`, main

Ce qui **marche** : ouvrir un pane agent Claude dans l'app (sur un worktree orca-host), choisir `1. Claude account with subscription`, ouvrir l'URL, coller le code. Écrit `~/.claude/.credentials.json` ; tous les panes suivants le réutilisent.

Ce qui **ne suffit pas** : `orca account add --agent claude`. Il enregistre un compte « managed » dans `~/.config/orca/claude-accounts/<id>/`, mais les panes sont par défaut en `selectionKey: host` (= le `~/.claude` de l'user) et l'ignorent. Utile seulement pour plusieurs comptes sur un même hôte.

Premier lancement par Orca (`claude --dangerously-skip-permissions`) : Claude demande d'accepter le mode bypass, une fois par machine → `bypassPermissionsModeAccepted: true` dans `~/.claude.json`. À poser dans `bootstrap.sh`.

Piste pour scripter : `claude setup-token` (token longue durée, abonnement) → `CLAUDE_CODE_OAUTH_TOKEN` dans un `EnvironmentFile` de l'unit. Vérifié : l'env de `orca-serve` est hérité par les Claude qu'Orca lance.

## 6. Par worktree — app, puis main

Création dans l'app : projet episto (orca-host), nom de branche, base `origin/nr/orca-worktree-config` (seule branche qui porte `orca.yaml`, PR epistofr/episto#2065 non mergée), setup **Run**.

- Hook `setup` (`orca.yaml`) : `bin/worktree init "$ORCA_WORKTREE_PATH"` → `.env.worktree` (ports 4001/4000/6173…), copie `api/.env` et `chat/.env`. **Vérifié le 2026-09-21 contre `orca serve` headless : tourne tout seul.**
- Puis **main** dans le terminal du worktree : `bin/worktree start --setup-db` (monte la stack, crée la base). À passer dans le hook `setup`.

Accès depuis le laptop (tailnet) : `http://100.105.104.105:4001` (API/nginx), `:4001/next` (web), `:4001/chat`.

## Ce qui reste à la main, à scripter

| Étape | Aujourd'hui | Cible |
|---|---|---|
| 1 création VM | laptop | à définir (pas de GitHub Actions) |
| 2.4 join Tailscale | approbation navigateur | `TS_AUTHKEY` |
| 3 appairage | laptop, `orca environment add` | client Orca — desktop ou mobile, à vérifier |
| 4 gh / git / clone / .env / image | terminal Orca | `bootstrap.sh` (user `orca`) avec `GH_TOKEN`, identité, `.env` fournis |
| 5 login Claude | pane Orca | `CLAUDE_CODE_OAUTH_TOKEN` |
| 5 acceptation bypass permissions | pane Orca, 1re fois | `bypassPermissionsModeAccepted` dans `~/.claude.json` |
| 6 start de la stack | terminal du worktree | hook `setup` de `orca.yaml` |
