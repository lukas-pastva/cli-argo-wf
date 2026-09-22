# argo-wf

A full-screen terminal dashboard for [Argo Workflows](https://argoproj.github.io/workflows/) — one bash file, no installation.

It talks to the **argo-server REST API** with your SSO bearer token, so it works for clusters you cannot reach with `kubectl`. It shows what is running in the namespaces you care about, tells you which workflows are parked on a **suspend node** (an approval gate), lets you **approve them from the terminal**, and — if you point it at an [Argo CD](https://argo-cd.readthedocs.io/) server — shows **what exactly is out of sync** underneath, so you know what you are approving.

```
╭─ Argo WF · argo.example.com ───────────────────────────────────────────────────────────── ↻ 1:42 ─╮
│    █████╗ ██████╗  ██████╗  ██████╗     ██╗    ██╗███████╗                                        │
│   ██╔══██╗██╔══██╗██╔════╝ ██╔═══██╗    ██║    ██║██╔════╝                                        │
│   ███████║██████╔╝██║  ███╗██║   ██║    ██║ █╗ ██║█████╗                                          │
│   ██╔══██║██╔══██╗██║   ██║██║   ██║    ██║███╗██║██╔══╝                                          │
│   ██║  ██║██║  ██║╚██████╔╝╚██████╔╝    ╚███╔███╔╝██║                                             │
│   ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝  ╚═════╝      ╚══╝╚══╝ ╚═╝                                             │
│                                                                                                   │
│   running: 1 · waiting: 1 · auto-refresh 2 min · Enter = open / approve / refresh · Esc = quit    │
│   argo >                                                                                          │
│   NAMESPACE   STATE       WORKFLOW         STARTED   DURATION  PROG   NOTE                        │
│   ─────────────────────────────────────────────────────────────────────────────────────────────   │
│ ▌ ↻ Refresh                                                                                       │
│   ─────────────────────────────────────────────────────────────────────────────────────────────   │
│   team-a      ⏸ Waiting   deploy-x7k2p     15m ago   15m       5/9    waiting for approval: prod  │
│               ↳ OutOfSync team-a-prod-eu                              1 changed                   │
│                              Deployment/api                           team-a                      │
│                                 replicas: 2 → 3                                                   │
│                                 image: registry.example.com/api:1.2.13 → …/api:1.2.14             │
│   ─────────────────────────────────────────────────────────────────────────────────────────────   │
│   team-b      · -         -                                           nothing running · last ✔ 2h │
╰───────────────────────────────────────────────────────────────────────────────────────────────────╯
```

## Requirements

| | |
|---|---|
| `bash` | 3.2 or newer — the one macOS ships is fine |
| [`fzf`](https://github.com/junegunn/fzf) | **0.45 or newer** (distribution packages are often older — use Homebrew or the release binaries) |
| `curl`, `jq` | jq 1.6+ |
| [`argocd`](https://argo-cd.readthedocs.io/en/stable/cli_installation/) CLI | optional, only for the out-of-sync view |

macOS: `brew install fzf jq` (and `brew install argocd` if you want the Argo CD part). Works on Linux and WSL as well.

## Install

```sh
curl -fsSLo argo-wf.sh https://raw.githubusercontent.com/lukas-pastva/cli-argo-wf/main/argo-wf.sh
chmod +x argo-wf.sh
./argo-wf.sh
```

Put it anywhere on your `PATH` if you like.

### Updating

Press Enter on the **⬆ Update argo-wf** row at the bottom of the table, or run `./argo-wf.sh --update`. The tool downloads the current `argo-wf.sh` from this repository, checks that it really is the script (shebang, version line, `bash -n`), shows `old → new` and — after you confirm — swaps the file with an atomic rename and restarts into it. Your settings and token live in the config file, so they are untouched.

It never checks or updates by itself: this tool holds a token that can approve deployments, so its code changes only when you say so. A copy inside a git checkout is left to `git pull`; without write access you get the `curl` command to run instead. `ARGO_WF_UPDATE_URL` points the update at a fork or an internal mirror.

## First run

The first start asks three things (they are remembered):

1. the **Argo Workflows server URL**, e.g. `https://argo.example.com`
2. the **namespaces** to watch, separated by spaces
3. optionally the **Argo CD server** host name (leave empty to switch that part off)

Or skip the questions:

```sh
./argo-wf.sh --server https://argo.example.com --namespaces "team-a team-b" --argocd argocd.example.com
```

`./argo-wf.sh --setup` asks again later.

### Signing in

Argo Workflows behind SSO has no `kubeconfig` to borrow, but its web UI hands out a bearer token. The tool opens `<server>/userinfo` in your browser; at the bottom of that page click **Copy to clipboard**, go back to the terminal and press **Enter** — the token is taken from the clipboard, verified against the server and saved.

You can also paste into the terminal instead (the whole copied snippet, or just the `Bearer …` value). Nothing you paste is echoed; the input row only reports how many characters arrived, and after verification shows the two ends of the token and its length.

SSO sessions expire (10 hours by default). When the server starts answering `401`, the sign-in screen comes back by itself. `./argo-wf.sh --logout` forgets the saved token.

## Keys

| | |
|---|---|
| `↑` `↓` | move (separators and diff rows are skipped) |
| type | filter the table |
| `Enter` on a workflow | open it in the browser |
| `Enter` on a **Waiting** workflow | approve it / open it |
| `Enter` on an Argo CD row | open the application — or that resource's diff — in the Argo CD UI |
| `Enter` on `↻ Refresh` | reload now |
| `Enter` on `⬆ Update argo-wf` | check for a newer version and install it |
| `Esc` | back / quit |

The table refreshes by itself (countdown in the top-right corner). The refresh is built in the background and swapped in without moving your cursor, and it waits while you are typing a filter or moving around. The last table is cached, so the next start shows something immediately and refreshes behind it.

## Approving

A workflow counts as *waiting* when it has a `Suspend` node in phase `Running`. Approving sends the same request as the **Resume** button of the web UI:

```
PUT /api/v1/workflows/<namespace>/<name>/resume
{"nodeFieldSelector": "displayName=<suspended node>,phase=Running"}
```

so the server records you as the one who resumed it, and your usual RBAC applies. Before anything is sent the tool re-checks that the workflow still waits, and asks for confirmation.

**Batches.** If the suspended node was expanded from a loop over items that have a `batch` key — its node name then looks like `deploy(2:batch:prod,…)` — the batch name is shown (`waiting for approval: prod`) and used below. Batches listed in `ARGO_WF_PROD_BATCHES` (default `prod`) need a second confirmation: you have to type the batch name.

## What is out of sync (Argo CD)

For every waiting workflow the tool looks up the Argo CD applications that belong to it and lists the resources that actually differ, with a compact `key: old → new` diff (changed part highlighted). Multi-line values — a ConfigMap's `config.yaml`, say — are compared line by line under a `data.config.yaml:` heading, so you see the lines that changed, not the whole file.

- Applications are found by **label selector** `ARGOCD_SELECTOR`, default `app={namespace},batch={batch}` — `{namespace}` is the workflow's namespace, `{batch}` the batch it waits on (terms with `{batch}` are dropped when there is none). Adjust it to however your applications are labelled.
- Keys in `ARGOCD_DIFF_IGNORE` (default `labels`) are removed from both sides before comparing — a chart version bump that only touches labels is noise. Applications that differ *only* there are treated as synced.
- Diffs longer than `ARGOCD_DIFF_LINES` (default 5, headings not counted) collapse into `… N changes`; press Enter on the resource to see the full diff in the Argo CD UI.
- Authentication is the `argocd` CLI's own: if you are not signed in, a row offers `argocd login <server> --sso`.

## Configuration

Everything lives in `~/.config/argo-wf/config` (mode `600`, plain `KEY="value"` lines; the file is parsed, never executed). Every key can also be given as an environment variable, which wins over the file. Command-line options win over both and are saved.

| Key | Default | |
|---|---|---|
| `ARGO_WF_SERVER` | – | Argo Workflows server URL |
| `ARGO_WF_NAMESPACES` | – | namespaces to watch, space separated |
| `ARGO_WF_REFRESH` | `120` | auto-refresh in seconds, `0` = off |
| `ARGO_WF_IDLE` | `5` | no refresh while you were active this many seconds ago |
| `ARGO_WF_LIMIT` | `20` | newest N workflows fetched per namespace |
| `ARGO_WF_PROD_BATCHES` | `prod` | batches that need the typed confirmation |
| `ARGO_WF_INSECURE` | – | `1` = skip TLS verification (`curl -k`) |
| `ARGOCD_SERVER` | – | Argo CD host name; empty = feature off |
| `ARGOCD_SELECTOR` | `app={namespace},batch={batch}` | label selector for a workflow's applications |
| `ARGOCD_FLAGS` | `--grpc-web` | extra flags for the `argocd` CLI |
| `ARGOCD_DIFF_LINES` | `5` | longer diffs collapse |
| `ARGOCD_DIFF_IGNORE` | `labels` | keys dropped from both sides of a diff |
| `ARGO_TOKEN` | – | the bearer token (written by the sign-in screen) |

`ARGO_WF_CONFIG=/path/to/file` or `--config` selects another config file — handy for a second server. If `ARGO_TOKEN` is exported in your shell (the Argo CLI uses the same variable) it is used as long as the config file has none, and tried as a fallback when the saved one expires.

## Security notes

- The token is stored in the config file with mode `600` and is never printed in full.
- Tokens are handed to `curl` on stdin, not on the command line, so they do not show up in `ps`.
- The tool only reads, except for the explicit, confirmed *resume* request described above.
- No background update checks, no telemetry; the only hosts contacted are your Argo servers — and GitHub when you ask for an update.

## License

[MIT](LICENSE)
