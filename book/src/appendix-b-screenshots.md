# Appendix B — Refreshing the screenshots

The screenshots are produced by `book/capture/capture.js`, a small Puppeteer
script that signs in to the Argo CD UI, walks the pages the book shows, scrubs
secrets out of the DOM, and saves PNGs into `book/src/images/`. It lives next
to the book so that whoever updates the UI or the chart can regenerate the
pictures rather than annotate stale ones.

## Setup

```bash
cd book/capture
npm install                                   # puppeteer (Chrome is downloaded on first use)
# if the download is blocked, point at a Chrome you have:
export PUPPETEER_EXECUTABLE_PATH=$HOME/.cache/puppeteer/chrome/linux-*/chrome-linux64/chrome
```

## Usage

```bash
ARGOCD_PASSWORD=… SHOT_SECRETS="$IBMCLOUD_API_KEY" APP_NS=bnk-sm-cli \
  node capture.js https://<argocd>:30443 ../src/images bnk-sm-cli \
    login apps app:healthy sync-panel \
    logs:bnk-init logs:bnk-cluster logs:bnk-preflight logs:bnk-up:complete logs:bnk-status \
    res:ConfigMap/bnk-config:summary res:ConfigMap/bnk-status:summary \
    settings-repos settings-projects
```

| Step | Produces |
|---|---|
| `login` | `01-login.png` — the form filled with a placeholder password, then signs in |
| `apps` | `02-applications.png` |
| `app[:suffix]` | `03-app.png` or `app-<suffix>.png` — the tree view |
| `sync-panel` | `04-sync-panel.png` |
| `logs:<job>[:suffix]` | `logs-<job>[-suffix].png` — the Job's Logs tab, scrolled to the end |
| `res:<Kind>/<name>[:tab][:suffix]` | `res-<name>-<tab>.png` — a resource's panel (`summary` shows the live manifest; `events`; `logs`) |
| `settings-repos`, `settings-projects` | `settings-repositories.png`, `settings-projects.png` |
| `details-summary[:suffix]` | `details-summary[-suffix].png` — Details → Summary (project, labels, sync options) |
| `delete-confirm` | `delete-confirm.png` + `delete-deleting.png` — types the name, keeps Foreground, clicks **OK** — really deletes |
| `details-sources[:suffix]` | `details-sources[-suffix].png` — Details → Sources with Source 1 expanded (Helm parameters / overrides) |
| `delete-dialog` | `delete-dialog.png` |

The uninstall chapter's pictures are the same steps run after switching
`lifecycle` to `down`: `app:down-outofsync` and `details-sources:down` before
the sync, `app:tearing-down` and `logs:bnk-down:running` during it,
`app:torn-down` and `logs:bnk-down` after, and `delete-dialog`.

## Secrets

The Argo CD UI renders manifests and environment, and a hook Job's environment
includes the IBM Cloud API key. Before every screenshot the script walks the
DOM and replaces any text matching a value passed in `SHOT_SECRETS` (newline
separated) and any `password=`/`api_key=`-shaped pair with `••••••••`. The
Argo CD password is added automatically. Pass secrets through the environment,
never on the command line.

## Timing

The UI is captured at 1600×1000 CSS pixels at 2× device scale. Pages are given
2.5–4 s to settle after `networkidle2`; a slow hub may need more — raise the
`goto` waits in the script. Log views are scrolled to the bottom so the final
lines (`Apply complete!`, the status write) are visible.
