#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# argo-wf.sh — full-screen terminal dashboard for Argo Workflows.
#
# Talks to the argo-server REST API with your SSO bearer token, so it works
# for clusters you cannot reach with kubectl. Shows what is running in the
# namespaces you care about, which workflows are parked on a suspend node
# (an approval gate), lets you approve them from the terminal and — when an
# Argo CD server is configured — shows what exactly is out of sync underneath.
#
# Single file, no installation: bash 3.2+, fzf 0.45+, curl, jq.
# Optional: the `argocd` CLI for the out-of-sync view.
#
#   ./argo-wf.sh                 first run asks for server + namespaces
#   ./argo-wf.sh --setup         change the settings
#   ./argo-wf.sh --help
#
# SPDX-License-Identifier: MIT
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

VERSION="1.0.0"

# ─── Colors & helpers ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

ok()   { printf "${GREEN}  ✔ ${NC}%s\n" "$*"; }
err()  { printf "${RED}  ✖ ${NC}%s\n" "$*" >&2; }

# ─── ASCII logo ──────────────────────────────────────────────────────
LOGO=$(cat <<'LOGO'
 █████╗ ██████╗  ██████╗  ██████╗     ██╗    ██╗███████╗
██╔══██╗██╔══██╗██╔════╝ ██╔═══██╗    ██║    ██║██╔════╝
███████║██████╔╝██║  ███╗██║   ██║    ██║ █╗ ██║█████╗
██╔══██║██╔══██╗██║   ██║██║   ██║    ██║███╗██║██╔══╝
██║  ██║██║  ██║╚██████╔╝╚██████╔╝    ╚███╔███╔╝██║
╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝  ╚═════╝      ╚══╝╚══╝ ╚═╝
LOGO
)
LOGO_WIDTH=56

# The logo, or nothing when the terminal has no room to spare for it.
logo_lines() {
  detect_cols
  (( TERM_LINES < 22 )) && return
  (( LOGO_WIDTH > TERM_COLS - 8 )) && return
  printf '%s\n' "$LOGO"
}

# ─── Framed full-screen boxes ────────────────────────────────────────
TERM_COLS=""
TERM_LINES=""
BOX_ROWS=0

# Cached until the next section / panel resets it (one stty per screen).
detect_cols() {
  if [[ -n "$TERM_COLS" && -n "$TERM_LINES" ]]; then return; fi
  local size
  size=$(stty size </dev/tty 2>/dev/null)
  if [[ "$size" =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
    TERM_LINES="${BASH_REMATCH[1]}"
    TERM_COLS="${BASH_REMATCH[2]}"
  fi
  [[ "${TERM_COLS:-0}" -lt 10 ]] && TERM_COLS="${COLUMNS:-80}"
  [[ "${TERM_COLS:-0}" -lt 10 ]] && TERM_COLS=80
  [[ "${TERM_LINES:-0}" -lt 6 ]] && TERM_LINES="${LINES:-24}"
  [[ "${TERM_LINES:-0}" -lt 6 ]] && TERM_LINES=24
}

box_width() {
  detect_cols
  echo $(( TERM_COLS - 4 ))
}

box_top() {
  local w line
  w=$(box_width)
  line=$(printf '─%.0s' $(seq 1 "$w"))
  printf "${BOLD}${CYAN}  ┌%s┐${NC}\n" "$line"
  BOX_ROWS=1
}

box_bottom() {
  local w line
  w=$(box_width)
  line=$(printf '─%.0s' $(seq 1 "$w"))
  printf "${BOLD}${CYAN}  └%s┘${NC}\n" "$line"
  BOX_ROWS=$(( BOX_ROWS + 1 ))
}

padded_line() {
  local max="$1" text="$2"
  if [[ ${#text} -gt $max ]]; then
    text="${text:0:$(( max - 2 ))}.."
  fi
  local pad=$(( max - ${#text} )) spaces=""
  [[ $pad -gt 0 ]] && spaces=$(printf '%*s' "$pad" "")
  printf '%s%s' "$text" "$spaces"
}

box_line() {
  local w content
  w=$(box_width)
  content=$(padded_line $(( w - 1 )) "$*")
  printf "${BOLD}${CYAN}  │${NC} %s${BOLD}${CYAN}│${NC}\n" "$content"
  BOX_ROWS=$(( BOX_ROWS + 1 ))
}

box_color_line() {
  local color="$1"; shift
  local w content
  w=$(box_width)
  content=$(padded_line $(( w - 1 )) "$*")
  printf "${BOLD}${CYAN}  │${NC} ${color}%s${NC}${BOLD}${CYAN}│${NC}\n" "$content"
  BOX_ROWS=$(( BOX_ROWS + 1 ))
}

section() {
  TERM_COLS=""; TERM_LINES=""
  clear
  box_top
  local logo_line
  while IFS= read -r logo_line; do
    [[ -n "$logo_line" ]] && box_color_line "${BOLD}${CYAN}" "  ${logo_line}"
  done < <(logo_lines)
  box_line ""
  box_line "  $1"
  box_line ""
}

# Pads the box with empty framed lines so it always fills the terminal —
# the same full-screen frame the fzf panels use.
section_close() {
  box_line ""
  detect_cols
  while (( BOX_ROWS < TERM_LINES - 2 )); do
    box_line ""
  done
  box_bottom
  BOX_ROWS=0
}

# sline <icon> <text> — one framed line; the icon may carry color codes, the
# text must not (it is padded by character count).
sline() {
  local icon="$1"; shift
  local w text
  w=$(box_width)
  text=$(padded_line $(( w - 4 )) "$*")
  printf "${BOLD}${CYAN}  │${NC} %b %s ${BOLD}${CYAN}│${NC}\n" "$icon" "$text"
  BOX_ROWS=$(( BOX_ROWS + 1 ))
}

# sline_color <icon> <color> <text> — like sline, with the whole text colored.
sline_color() {
  local icon="$1" color="$2"; shift 2
  local w text
  w=$(box_width)
  text=$(padded_line $(( w - 4 )) "$*")
  printf "${BOLD}${CYAN}  │${NC} %b ${color}%s${NC} ${BOLD}${CYAN}│${NC}\n" "$icon" "$text"
  BOX_ROWS=$(( BOX_ROWS + 1 ))
}

sblank() { box_line ""; }

# Terminal state that has to survive Ctrl-C (see cleanup).
STTY_SAVED=""

# Drops whatever is waiting in the tty input queue (stray key presses, the
# tail of a paste). Pure stty + dd so it also works on bash 3.2, whose `read`
# has no fractional timeouts.
flush_input() {
  local saved
  saved=$(stty -g </dev/tty 2>/dev/null) || return 0
  stty -icanon -echo min 0 time 0 </dev/tty 2>/dev/null
  while [[ -n "$(dd bs=4096 count=1 2>/dev/null </dev/tty)" ]]; do :; done
  stty "$saved" </dev/tty 2>/dev/null
}

# Closes the box with the hint inside the frame, then waits for any key.
pause_close() {
  sblank
  sline "${DIM}⏎${NC}" "Press any key to go back ..."
  section_close
  flush_input
  read -rsn1 </dev/tty
}

# ─── Full-screen fzf panels ──────────────────────────────────────────
# Every interactive step is one full-screen fzf panel with a rounded border
# labelled with the feature name, so all input happens inside the frame.
# Esc always aborts and returns 1.
UI_TITLE=""
UI_RESULT=""
UI_OPTS=()

_ui_opts() {
  TERM_COLS=""; TERM_LINES=""
  UI_OPTS=(
    --layout=reverse
    --height=100%
    --border=rounded
    --border-label=" ${UI_TITLE} "
    --border-label-pos=3
    --no-info
    --no-sort
    --bind=esc:abort,ctrl-c:abort
    --color=header:cyan,prompt:green,pointer:green,marker:green,border:cyan,label:cyan
  )
}

# Header for a panel: the logo, a blank line, then the caller's text.
_ui_header() {
  local text="$1" logo
  logo=$(logo_lines)
  if [[ -n "$logo" ]]; then
    printf '%s\n\n%s\n' "$(printf '%s\n' "$logo" | sed 's/^/  /')" "  ${text}"
  else
    printf '%s\n' "  ${text}"
  fi
}

# ui_select <candidates> <prompt> <header> — pick one line; Esc returns 1.
# UI_EXTRA_OPTS lets a caller add fzf options for one panel (e.g. an extra
# key binding); it is consumed and reset by the next ui_select call.
UI_EXTRA_OPTS=()

ui_select() {
  UI_RESULT=""
  local candidates="$1" prompt_text="$2" header_text="$3"
  [[ -z "$candidates" ]] && { UI_EXTRA_OPTS=(); return 1; }
  _ui_opts
  local extra=(${UI_EXTRA_OPTS[@]+"${UI_EXTRA_OPTS[@]}"})
  UI_EXTRA_OPTS=()
  local sel
  flush_input
  sel=$(FZF_DEFAULT_COMMAND="" FZF_DEFAULT_OPTS="" fzf "${UI_OPTS[@]}" \
    ${extra[@]+"${extra[@]}"} \
    --prompt="  ${prompt_text} > " \
    --header="$(_ui_header "$header_text")" \
    --header-first \
    --query="" <<< "$candidates") || return 1
  [[ -z "$sel" ]] && return 1
  UI_RESULT="$sel"
}

# ui_input <prompt> <header> [prefill] — fzf with no candidates doubles as a
# text prompt: what you type comes back via --print-query, Esc returns 1.
# Only for short, single-line values: fzf caps the query at 1000 characters
# and submits on the first newline of a paste — secrets go through ui_paste.
ui_input() {
  UI_RESULT=""
  local prompt_text="$1" header_text="$2" initial="${3:-}"
  _ui_opts
  local out rc
  flush_input
  out=$(FZF_DEFAULT_COMMAND="" FZF_DEFAULT_OPTS="" fzf "${UI_OPTS[@]}" \
    --print-query \
    --disabled \
    --prompt="  ${prompt_text} > " \
    --header="$(_ui_header "$header_text")" \
    --header-first \
    --query="$initial" </dev/null)
  rc=$?
  # 0 = match accepted, 1 = "no match" (always, with an empty list),
  # 130 = Esc / Ctrl-C.
  (( rc == 0 || rc == 1 )) || return 1
  # Trim surrounding whitespace.
  out="${out#"${out%%[![:space:]]*}"}"
  out="${out%"${out##*[![:space:]]}"}"
  UI_RESULT="$out"
}

# ─── In-frame paste prompt ───────────────────────────────────────────
# ui_paste <heading> <"icon|text" lines…> — a framed screen whose last row is
# an input row. Nothing typed or pasted is echoed (no flicker, no secret on
# screen); the row only reports how many characters arrived. Takes whatever
# the terminal delivers: multi-line pastes and values of any length.
# Enter on an empty row returns "" (rc 0); Esc / Ctrl-C return 1.
# paste_status redraws the input row afterwards (e.g. "token received …").
UI_PASTE_ROW=0
UI_PASTE_IDLE="waiting — press Enter, or paste here and press Enter"

paste_status() {
  local icon="$1" color="$2"; shift 2
  printf '\033[%d;1H' "$UI_PASTE_ROW"
  sline_color "$icon" "$color" "$*"
  printf '\033[%d;1H' "$TERM_LINES"
}

ui_paste() {
  UI_RESULT=""
  local heading="$1"; shift
  section "$heading"
  local spec
  for spec in "$@"; do
    if [[ -z "$spec" ]]; then sblank; else sline "${spec%%|*}" "${spec#*|}"; fi
  done
  sblank
  sline_color "${GREEN}❯${NC}" "$GREEN" "$UI_PASTE_IDLE"
  UI_PASTE_ROW=$BOX_ROWS
  section_close

  local buf="" chunk more rc=0 cr=$'\r' nl=$'\n' p_on=$'\e[200~' p_off=$'\e[201~'
  flush_input
  STTY_SAVED=$(stty -g </dev/tty 2>/dev/null) || { STTY_SAVED=""; return 1; }
  printf '\033[?25l'
  while true; do
    # block for the first byte, then slurp the rest of the burst (a paste
    # arrives as one burst; 0.2 s of silence ends it)
    stty -icanon -echo -isig min 1 time 0 </dev/tty 2>/dev/null
    chunk=$(dd bs=4096 count=1 2>/dev/null </dev/tty; printf x); chunk="${chunk%x}"
    [[ -n "$chunk" ]] || { rc=1; break; }
    stty min 0 time 2 </dev/tty 2>/dev/null
    while true; do
      more=$(dd bs=4096 count=1 2>/dev/null </dev/tty; printf x); more="${more%x}"
      [[ -n "$more" ]] || break
      chunk+="$more"
    done
    chunk="${chunk//$p_on/}"; chunk="${chunk//$p_off/}"   # bracketed-paste markers
    case "$chunk" in
      $'\e')       rc=1; break ;;
      *$'\x03'*)   rc=1; break ;;
      $'\e'*)      continue ;;                  # arrow keys & co.
      $'\x7f'|$'\b') buf="${buf%?}" ;;
      $'\x15')     buf="" ;;
      *)           buf+="$chunk" ;;
    esac
    buf="${buf//$cr/$nl}"
    [[ "$buf" == *"$nl"* ]] && break
    if [[ -n "$buf" ]]; then
      paste_status "${GREEN}❯${NC}" "$GREEN" "${#buf} characters received — Enter = confirm · Esc = back"
    else
      paste_status "${GREEN}❯${NC}" "$GREEN" "$UI_PASTE_IDLE"
    fi
  done
  stty "$STTY_SAVED" </dev/tty 2>/dev/null; STTY_SAVED=""
  printf '\033[?25h'
  (( rc == 0 )) || return 1
  buf="${buf#"${buf%%[![:space:]]*}"}"
  buf="${buf%"${buf##*[![:space:]]}"}"
  UI_RESULT="$buf"
}

# ─── Configuration ───────────────────────────────────────────────────
# Settings live in one KEY="value" file (mode 600; it also holds the token).
# Precedence: command line > environment > config file > defaults. The one
# exception is ARGO_TOKEN: the file wins, because that copy is the one this
# tool refreshes — a token exported in the shell is kept as a fallback.
CONFIG_FILE="${ARGO_WF_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/argo-wf/config}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/argo-wf"
CONFIG_VARS="ARGO_WF_SERVER ARGO_WF_NAMESPACES ARGO_WF_LIMIT ARGO_WF_REFRESH ARGO_WF_IDLE
             ARGO_WF_PROD_BATCHES ARGO_WF_INSECURE ARGOCD_SERVER ARGOCD_SELECTOR
             ARGOCD_FLAGS ARGOCD_DIFF_LINES ARGOCD_DIFF_IGNORE"

NAMESPACES=()
ARGO_TOKEN_ALT=""
CURL_OPTS=()

config_set() {
  local key="$1" value="$2" tmp
  mkdir -p "$(dirname "$CONFIG_FILE")"
  tmp="${CONFIG_FILE}.tmp.$$"
  ( umask 077
    { [[ -f "$CONFIG_FILE" ]] && grep -v "^${key}=" "$CONFIG_FILE"
      printf '%s="%s"\n' "$key" "$value"; } > "$tmp" )
  mv "$tmp" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

config_unset() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  local tmp="${CONFIG_FILE}.tmp.$$"
  ( umask 077; grep -v "^${1}=" "$CONFIG_FILE" > "$tmp" )
  mv "$tmp" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

# The file is parsed, never sourced: only known keys, only KEY=value lines.
config_load() {
  local v line key value env_token="${ARGO_TOKEN:-}" file_token=""
  for v in $CONFIG_VARS; do eval "_env_${v}=\"\${${v}:-}\""; eval "${v}=''"; done
  if [[ -f "$CONFIG_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in ''|\#*) continue ;; esac
      [[ "$line" == *=* ]] || continue
      key="${line%%=*}"; value="${line#*=}"
      value="${value%\"}"; value="${value#\"}"
      if [[ "$key" == "ARGO_TOKEN" ]]; then file_token="$value"; continue; fi
      case " $(echo $CONFIG_VARS) " in *" $key "*) printf -v "$key" '%s' "$value" ;; esac
    done < "$CONFIG_FILE"
  fi
  for v in $CONFIG_VARS; do
    eval "[[ -n \"\$_env_${v}\" ]] && ${v}=\"\$_env_${v}\""
  done
  if [[ -n "$file_token" ]]; then ARGO_TOKEN="$file_token"; ARGO_TOKEN_ALT="$env_token"
  else ARGO_TOKEN="$env_token"; ARGO_TOKEN_ALT=""; fi
}

# Defaults + normalisation; called after config_load and after every change.
config_apply() {
  : "${ARGO_WF_LIMIT:=20}"          # newest N workflows fetched per namespace
  : "${ARGO_WF_REFRESH:=120}"       # auto-refresh in seconds, 0 = off
  : "${ARGO_WF_IDLE:=5}"            # no refresh while you were active this recently
  : "${ARGO_WF_PROD_BATCHES:=prod}" # batches that need a typed confirmation
  # (not ${VAR:=…}: the first "}" of the placeholders would end the expansion)
  [[ -n "$ARGOCD_SELECTOR" ]] || ARGOCD_SELECTOR='app={namespace},batch={batch}'
  : "${ARGOCD_FLAGS:=--grpc-web}"
  : "${ARGOCD_DIFF_LINES:=5}"       # longer diffs collapse into "… N changes"
  : "${ARGOCD_DIFF_IGNORE:=labels}" # keys dropped from both sides of the diff
  if [[ -n "$ARGO_WF_SERVER" ]]; then
    [[ "$ARGO_WF_SERVER" == http*://* ]] || ARGO_WF_SERVER="https://${ARGO_WF_SERVER}"
    ARGO_WF_SERVER="${ARGO_WF_SERVER%/}"
  fi
  ARGOCD_SERVER="${ARGOCD_SERVER#http://}"; ARGOCD_SERVER="${ARGOCD_SERVER#https://}"
  ARGOCD_SERVER="${ARGOCD_SERVER%/}"
  # shellcheck disable=SC2206
  NAMESPACES=(${ARGO_WF_NAMESPACES//,/ })
  CURL_OPTS=()
  [[ "${ARGO_WF_INSECURE:-}" == "1" ]] && CURL_OPTS=(-k)
  CACHE_KEY=$(printf '%s' "${ARGO_WF_SERVER}|${NAMESPACES[*]:-}|${ARGOCD_SERVER}|${ARGOCD_SELECTOR}" | cksum | awk '{print $1}')
}

# First run / --setup: three short prompts, all optional to change.
setup_wizard() {
  UI_TITLE="Argo WF — setup"
  ui_input "server" "Argo Workflows server URL, e.g. https://argo.example.com · Enter = confirm · Esc = cancel" \
    "$ARGO_WF_SERVER" || return 1
  [[ -n "$UI_RESULT" ]] || return 1
  ARGO_WF_SERVER="$UI_RESULT"
  ui_input "namespaces" "Namespaces to watch, separated by spaces · Enter = confirm · Esc = cancel" \
    "${NAMESPACES[*]:-}" || return 1
  [[ -n "$UI_RESULT" ]] || return 1
  ARGO_WF_NAMESPACES="${UI_RESULT//,/ }"
  ui_input "argo cd" "Optional — Argo CD server (host name): shows what is out of sync under a workflow waiting for approval · empty = off" \
    "$ARGOCD_SERVER" || return 1
  ARGOCD_SERVER="$UI_RESULT"
  config_apply
  config_set ARGO_WF_SERVER "$ARGO_WF_SERVER"
  config_set ARGO_WF_NAMESPACES "${NAMESPACES[*]}"
  config_set ARGOCD_SERVER "$ARGOCD_SERVER"
}

# ─── Argo Workflows API ──────────────────────────────────────────────
_open_url() {
  if command -v open >/dev/null; then open "$1" >/dev/null 2>&1
  elif command -v xdg-open >/dev/null; then xdg-open "$1" >/dev/null 2>&1
  elif command -v wslview >/dev/null; then wslview "$1" >/dev/null 2>&1
  fi
}

_clipboard() {
  if command -v pbpaste >/dev/null; then pbpaste
  elif command -v wl-paste >/dev/null; then wl-paste --no-newline
  elif command -v xclip >/dev/null; then xclip -o -selection clipboard
  elif command -v xsel >/dev/null; then xsel --clipboard --output
  elif command -v powershell.exe >/dev/null; then powershell.exe -NoProfile -Command Get-Clipboard | tr -d '\r'
  fi 2>/dev/null
}

# GNU first: on Linux `stat -f` means something else and still prints.
_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# _argo_api <path> — body in ARGO_BODY, HTTP status in ARGO_HTTP_CODE (no
# subshell, so the caller sees the code; rc 0 only for HTTP 200). The token
# goes to curl on stdin, not on the command line, to stay out of `ps`.
ARGO_HTTP_CODE=""
ARGO_BODY=""
_argo_api() {
  local out
  if ! out=$(printf 'header = "Authorization: %s"\n' "${ARGO_TOKEN:-}" \
             | curl -sS --max-time 20 ${CURL_OPTS[@]+"${CURL_OPTS[@]}"} -K - \
                    -w $'\n%{http_code}' "${ARGO_WF_SERVER}${1}" 2>&1); then
    ARGO_HTTP_CODE="000"; ARGO_BODY="$out"; return 1
  fi
  ARGO_HTTP_CODE="${out##*$'\n'}"
  ARGO_BODY="${out%$'\n'*}"
  [[ "$ARGO_HTTP_CODE" == "200" ]]
}

# _argo_api_put <path> <json> — like _argo_api, but a PUT with a JSON body.
_argo_api_put() {
  local out
  if ! out=$(printf 'header = "Authorization: %s"\n' "${ARGO_TOKEN:-}" \
             | curl -sS --max-time 30 ${CURL_OPTS[@]+"${CURL_OPTS[@]}"} -K - -X PUT \
                    -H 'Content-Type: application/json' -d "$2" \
                    -w $'\n%{http_code}' "${ARGO_WF_SERVER}${1}" 2>&1); then
    ARGO_HTTP_CODE="000"; ARGO_BODY="$out"; return 1
  fi
  ARGO_HTTP_CODE="${out##*$'\n'}"
  ARGO_BODY="${out%$'\n'*}"
  [[ "$ARGO_HTTP_CODE" == "200" ]]
}

# argo_wf_whoami — 0 + name in ARGO_WHO, else 1 (error in ARGO_BODY/ARGO_HTTP_CODE).
ARGO_WHO=""
argo_wf_whoami() {
  ARGO_WHO=""
  _argo_api "/api/v1/userinfo" || return 1
  ARGO_WHO=$(jq -r '.email // .subject // "?"' <<< "$ARGO_BODY" 2>/dev/null)
}

# Token from pasted text: the whole snippet of the UI's "Copy to clipboard"
# (export ARGO_TOKEN='Bearer v2:…'), a bare "Bearer …" / "v2:…", or a lone
# token string.
_argo_token_from_text() {
  local t
  t=$(sed -n "s/^export ARGO_TOKEN='\(.*\)'.*$/\1/p" <<< "$1" | head -1)
  [[ -n "$t" ]] || t=$(grep -oE '(Bearer )?v2:[A-Za-z0-9._=-]+' <<< "$1" | head -1)
  [[ -n "$t" ]] || t=$(grep -oE 'Bearer [A-Za-z0-9._=:-]+' <<< "$1" | head -1)
  if [[ -z "$t" && "$1" =~ ^[A-Za-z0-9._=:-]{20,}$ ]]; then t="$1"; fi
  [[ -n "$t" ]] || return 1
  [[ "$t" == Bearer* ]] || t="Bearer $t"
  printf '%s' "$t"
}

# What is safe to show of a token: its two ends and the length.
_mask_token() {
  local t="$1" n=${#1}
  if (( n > 32 )); then printf '%s…%s (%d characters)' "${t:0:18}" "${t:$(( n - 6 ))}" "$n"
  else printf '(%d characters)' "$n"; fi
}

# argo_wf_ensure_token [force] — 0 = token valid, 1 = the user backed out.
argo_wf_ensure_token() {
  local force="${1:-}"
  if [[ -z "$force" ]] && argo_wf_whoami; then
    return 0
  fi
  # the other copy (exported in the shell vs. saved in the config file)
  if [[ -n "$ARGO_TOKEN_ALT" && "$ARGO_TOKEN_ALT" != "${ARGO_TOKEN:-}" ]]; then
    local prev="${ARGO_TOKEN:-}"
    ARGO_TOKEN="$ARGO_TOKEN_ALT"; ARGO_TOKEN_ALT=""
    argo_wf_whoami && return 0
    ARGO_TOKEN="$prev"
  fi

  local host="${ARGO_WF_SERVER#http*://}" why raw t msg="" opened=0
  if [[ -n "${ARGO_TOKEN:-}" ]]; then
    why="The saved token is no longer valid (the SSO session expired) — a new one is needed."
  else
    why="No token yet — the server sits behind SSO and its web UI hands the token out."
  fi
  while true; do
    if (( ! opened )); then _open_url "${ARGO_WF_SERVER}/userinfo"; opened=1; fi
    ui_paste "Argo WF — sign in (${host})" \
      "${YELLOW}⚠${NC}|${why}" \
      "${CYAN}▸${NC}|Opened ${ARGO_WF_SERVER}/userinfo in your browser (sign in there if asked)." \
      "${CYAN}▸${NC}|At the bottom of that page click “Copy to clipboard”, then come back here." \
      "" \
      "${CYAN}▸${NC}|Enter = take the token from the clipboard" \
      "${CYAN}▸${NC}|or paste it here and press Enter — nothing is echoed, the row below shows what arrived" \
      "${CYAN}▸${NC}|Esc = back" \
      ${msg:+""} ${msg:+"${RED}✖${NC}|${msg}"} || return 1
    raw="$UI_RESULT"
    [[ -n "$raw" ]] || raw=$(_clipboard)
    if ! t=$(_argo_token_from_text "$raw"); then
      msg="No token found in that (${#raw} characters) — expected the copied snippet with ARGO_TOKEN='Bearer …'."
      continue
    fi
    paste_status "${GREEN}✔${NC}" "$GREEN" "Token received: $(_mask_token "$t") — verifying …"
    local prev="${ARGO_TOKEN:-}"
    ARGO_TOKEN="$t"
    if ! argo_wf_whoami; then
      ARGO_TOKEN="$prev"
      if [[ "$ARGO_HTTP_CODE" == "000" ]]; then
        msg="Cannot reach ${ARGO_WF_SERVER} — $(head -1 <<< "$ARGO_BODY")"
      else
        msg="The server rejected that token (HTTP ${ARGO_HTTP_CODE}) — $(_mask_token "$t")."
      fi
      continue
    fi
    config_set ARGO_TOKEN "$t"
    paste_status "${GREEN}✔${NC}" "$GREEN" "Signed in as ${ARGO_WHO} — token $(_mask_token "$t") saved to ${CONFIG_FILE/#$HOME/~}"
    sleep 2
    return 0
  done
}

# _argo_ns_rows <namespace> — TSV rows in ARGO_ROWS: phase, name, age,
# duration, progress (the server returns newest first; the API cannot filter
# by phase, so that happens later in _argo_wf_build).
ARGO_ROWS=""
ARGO_LIST_FIELDS="items.metadata.name,items.metadata.creationTimestamp,items.status.phase,items.status.startedAt,items.status.finishedAt,items.status.progress"
_argo_ns_rows() {
  ARGO_ROWS=""
  if [[ -n "$ARGO_PREFETCH_DIR" && -f "${ARGO_PREFETCH_DIR}/${1}.code" ]]; then
    ARGO_HTTP_CODE=$(cat "${ARGO_PREFETCH_DIR}/${1}.code")
    ARGO_BODY=$(cat "${ARGO_PREFETCH_DIR}/${1}.json")
    [[ "$ARGO_HTTP_CODE" == "200" ]] || return 1
  else
    _argo_api "/api/v1/workflows/${1}?listOptions.limit=${ARGO_WF_LIMIT}&fields=${ARGO_LIST_FIELDS}" || return 1
  fi
  ARGO_ROWS=$(jq -r '
    def hum: if . < 60 then "\(.)s"
             elif . < 3600 then "\(./60|floor)m"
             elif . < 86400 then "\(./3600|floor)h \((. % 3600)/60|floor)m"
             else "\(./86400|floor)d \((. % 86400)/3600|floor)h" end;
    now as $now
    | (.items // [])[]
    | ((.status.startedAt // .metadata.creationTimestamp) | fromdateiso8601) as $s
    | (if .status.finishedAt then (.status.finishedAt | fromdateiso8601) else $now end) as $f
    | [ (.status.phase // "Pending"), .metadata.name,
        (($now - $s) | if . < 0 then 0 else . end | floor | hum),
        (($f - $s) | if . < 0 then 0 else . end | floor | hum),
        (.status.progress // "") ]
    | @tsv' <<< "$ARGO_BODY")
}

# _argo_wf_waiting <ns> <name> — ARGO_WAIT = what a running workflow is parked
# on: a Suspend node in phase Running (an approval gate, a postponement).
# ARGO_WAIT_NODE = displayName of the first such node (what "approve"
# resumes). When the node comes from a loop over items with a `batch` key —
# node name "deploy(2:batch:prod,…)" — the batch lands in ARGO_WAIT_BATCH.
ARGO_WAIT=""
ARGO_WAIT_BATCH=""
ARGO_WAIT_NODE=""
_argo_wf_waiting() {
  ARGO_WAIT=""; ARGO_WAIT_BATCH=""; ARGO_WAIT_NODE=""
  _argo_api "/api/v1/workflows/${1}/${2}?fields=status.nodes" || return 0
  local line display batch parts=""
  while IFS=$'\t' read -r display batch; do
    [[ -n "$display" ]] || continue
    [[ -z "$ARGO_WAIT_NODE" ]] && ARGO_WAIT_NODE="$display"
    [[ -z "$ARGO_WAIT_BATCH" && -n "$batch" ]] && ARGO_WAIT_BATCH="$batch"
    if [[ "$display" == approv* ]]; then
      line="waiting for approval${batch:+: ${batch}}"
    else
      line="suspended: ${display}${batch:+ (${batch})}"
    fi
    parts+="${parts:+ · }${line}"
  done < <(jq -r '
    (.status.nodes // {}) | to_entries[] | .value
    | select(.type == "Suspend" and .phase == "Running")
    | [ .displayName, ((.name | capture("batch:(?<b>[^,)]+)") | .b) // "") ]
    | @tsv' <<< "$ARGO_BODY" 2>/dev/null)
  ARGO_WAIT="$parts"
}

# ─── Argo CD: what is out of sync under a waiting workflow ───────────
# Enabled by ARGOCD_SERVER + the `argocd` CLI (sign in: argocd login --sso).
# Applications are matched by label selector ARGOCD_SELECTOR, where
# {namespace} = the workflow's namespace and {batch} = the batch the workflow
# waits on; terms with {batch} are dropped when there is no batch.
argocd_enabled() {
  [[ -n "${ARGOCD_SERVER:-}" ]] && command -v argocd >/dev/null
}

_argocd_selector() {
  local ns="$1" batch="$2" term out="" IFS=','
  for term in $ARGOCD_SELECTOR; do
    [[ "$term" == *"{batch}"* && -z "$batch" ]] && continue
    term="${term//\{namespace\}/$ns}"; term="${term//\{batch\}/$batch}"
    out+="${out:+,}${term}"
  done
  printf '%s' "$out"
}

# _argocd_apps_json <label-selector> — JSON list of applications in
# ARGOCD_JSON (not stdout, a subshell would lose ARGOCD_ERR); rc 1 = the CLI
# failed (ARGOCD_ERR = text), rc 2 = not signed in.
ARGOCD_ERR=""
ARGOCD_JSON=""
_argocd_apps_json() {
  local out
  ARGOCD_ERR=""; ARGOCD_JSON=""
  # shellcheck disable=SC2086
  if ! out=$(argocd app list --server "$ARGOCD_SERVER" $ARGOCD_FLAGS -l "$1" -o json 2>&1); then
    ARGOCD_ERR=$(head -1 <<< "$out" | sed 's/^[A-Z]*\[[0-9]*\] *//')
    case "$out" in
      *nauthenticated*|*"token is expired"*|*"invalid session"*|*"failed to get user info"*|*"Logged In: false"*|*"not logged in"*) return 2 ;;
    esac
    return 1
  fi
  ARGOCD_JSON="$out"
}

argocd_login() {
  section "Argo CD sign-in (${ARGOCD_SERVER})"
  sline "${CYAN}▸${NC}" "Running: argocd login ${ARGOCD_SERVER} --sso ${ARGOCD_FLAGS} (SSO in your browser)"
  sblank
  section_close
  # shellcheck disable=SC2086
  if argocd login "$ARGOCD_SERVER" --sso $ARGOCD_FLAGS </dev/tty; then
    ok "Signed in"; sleep 1
  else
    err "Sign-in failed"; sleep 2
  fi
}

# The CLI's token for ARGOCD_SERVER from ~/.config/argocd/config (no yq).
_argocd_token() {
  awk -v srv="$ARGOCD_SERVER" '
    /^users:/ { u = 1 } /^[a-z]/ && !/^users:/ { u = 0 }
    u && /auth-token:/ { t = $NF }
    u && /name:/ { if ($NF == srv) { print t; exit } }
  ' "${ARGOCD_CONFIG:-$HOME/.config/argocd/config}" 2>/dev/null
}

# _argocd_app_diff <app> <app-namespace> — diff of an out-of-sync application
# via the API's /managed-resources (normalizedLiveState = live,
# predictedLiveState = target; both JSON). Keys listed in ARGOCD_DIFF_IGNORE
# are removed from both sides anywhere in the tree (default: labels — a chart
# version bump in labels is only noise), then the pretty-printed JSON is
# diffed line by line; hunks "NcM" with the same key become "key: old → new".
# Resources differing only in ignored keys are counted, not listed.
# Output rows (separator \x1f) in ARGOCD_DIFF:
#   "res<S>Kind/name<S>ns<S>group", "chg<S>Kind/name<S>ns<S>group<S>chg|add|del<S>text"
# rc 2 = 401 (not signed in), rc 1 = other error (ARGOCD_ERR).
ARGOCD_DIFF=""
ARGOCD_DIFF_LABELONLY=0
_argocd_app_diff() {
  local app="$1" appns="$2" S=$'\x1f' tok code tmp ign="" k
  ARGOCD_DIFF=""; ARGOCD_DIFF_LABELONLY=0; ARGOCD_ERR=""
  tok=$(_argocd_token)
  [[ -n "$tok" ]] || return 2
  tmp="${TMP_PREFIX}.cd.${RANDOM}"
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$tok" \
    | curl -s -m 60 ${CURL_OPTS[@]+"${CURL_OPTS[@]}"} -K - -o "$tmp.json" -w '%{http_code}' \
      "https://${ARGOCD_SERVER}/api/v1/applications/${app}/managed-resources?${appns:+appNamespace=${appns}&}fields=items.kind,items.name,items.namespace,items.group,items.normalizedLiveState,items.predictedLiveState,items.liveState,items.targetState")
  if [[ "$code" == "401" ]]; then rm -f "$tmp.json"; return 2; fi
  if [[ "$code" != "200" ]]; then ARGOCD_ERR="managed-resources HTTP ${code}"; rm -f "$tmp.json"; return 1; fi
  for k in $ARGOCD_DIFF_IGNORE; do ign+="${ign:+, }.[\"${k}\"]"; done
  local strip="walk(if type == \"object\" then del(${ign:-.__none__}) else . end)"
  # one line per resource: kind ns name group differs_without_ignored(0/1)
  # differs_at_all(0/1) live_b64 target_b64 (JSON through base64 — @tsv
  # would escape the backslashes inside JSON strings)
  local kind ns name group real any live target lo=0
  while IFS="$S" read -r kind ns name group real any live target; do
    [[ -n "$kind" ]] || continue
    if (( real == 0 )); then (( any == 1 )) && lo=$((lo + 1)); continue; fi
    ARGOCD_DIFF+="res${S}${kind}/${name}${S}${ns}${S}${group}"$'\n'
    base64 --decode <<< "$live"   | jq -S "$strip" > "$tmp.live" 2>/dev/null
    base64 --decode <<< "$target" | jq -S "$strip" > "$tmp.target" 2>/dev/null
    # HO/HN/HE = markers start-old / start-new / end of the changed part
    # (colors are added when the table is drawn; not \x01 — bash's CTLESC)
    ARGOCD_DIFF+=$(diff "$tmp.live" "$tmp.target" | LC_ALL=C awk -v S="$S" -v HO=$'\x1c' -v HN=$'\x1d' -v HE=$'\x1e' -v res="${kind}/${name}" -v ns="$ns" -v grp="$group" '
      function clean(s,   k, v) {
        sub(/^[ \t]+/, "", s); sub(/,$/, "", s)
        if (s ~ /^"[^"]+": /) { k = substr(s, 2, index(s, "\": ") - 2); v = substr(s, index(s, "\": ") + 3) }
        else { k = ""; v = s }
        if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
        return (k == "") ? v : k ": " v
      }
      function key(s) { return (s ~ /: /) ? substr(s, 1, index(s, ": ") - 1) : "" }
      function noise(s) { return s ~ /^[][{}]*$/ }
      # hl(a, b) — marks in a/b exactly the part that differs (common prefix
      # and suffix stay unmarked), result in HA/HB. Boundaries move out to the
      # word edge (1.2.13 → 1.2.14 highlights "13"/"14", not just "3"/"4");
      # bytes >= 0x80 count as "word" so a UTF-8 character is never split
      # (awk works on bytes here).
      function isw(c) { return c ~ /[A-Za-z0-9]/ || c >= "\200" }
      function hl(a, b,   la, lb, m, p, s) {
        la = length(a); lb = length(b); m = (la < lb) ? la : lb
        p = 0; while (p < m && substr(a, p + 1, 1) == substr(b, p + 1, 1)) p++
        while (p > 0 && isw(substr(a, p, 1)) && (isw(substr(a, p + 1, 1)) || isw(substr(b, p + 1, 1)))) p--
        s = 0; while (s < m - p && substr(a, la - s, 1) == substr(b, lb - s, 1)) s++
        while (s > 0 && isw(substr(a, la - s + 1, 1)) && ((la - s > p && isw(substr(a, la - s, 1))) || (lb - s > p && isw(substr(b, lb - s, 1))))) s--
        HA = substr(a, 1, p) ((la - s > p) ? HO substr(a, p + 1, la - s - p) HE : "") substr(a, la - s + 1)
        HB = substr(b, 1, p) ((lb - s > p) ? HN substr(b, p + 1, lb - s - p) HE : "") substr(b, lb - s + 1)
      }
      function flush(   i, ko, kn) {
        if (type == "c" && no == nn) {
          for (i = 1; i <= no; i++) {
            ko = key(old[i]); kn = key(new[i])
            if (ko != "" && ko == kn) {
              hl(substr(old[i], length(ko) + 3), substr(new[i], length(kn) + 3))
              print "chg" S res S ns S grp S "chg" S ko ": " HA " → " HB
            } else {
              hl(old[i], new[i])
              print "chg" S res S ns S grp S "del" S HA; print "chg" S res S ns S grp S "add" S HB
            }
          }
        } else {
          for (i = 1; i <= no; i++) print "chg" S res S ns S grp S "del" S old[i]
          for (i = 1; i <= nn; i++) print "chg" S res S ns S grp S "add" S new[i]
        }
        no = 0; nn = 0; type = ""
      }
      /^[0-9,]+[acd][0-9,]+$/ { flush(); type = $0; gsub(/[0-9,]/, "", type); next }
      /^< / { s = clean(substr($0, 3)); if (!noise(s)) old[++no] = s; next }
      /^> / { s = clean(substr($0, 3)); if (!noise(s)) new[++nn] = s; next }
      END { flush() }
    ')$'\n'
  done < <(jq -r '
      .items[]?
      | (.normalizedLiveState // .liveState // "{}" | fromjson) as $l
      | (.predictedLiveState // .targetState // "{}" | fromjson) as $t
      | [ .kind, (.namespace // ""), .name, (.group // ""),
          (if ($l | '"$strip"') != ($t | '"$strip"') then 1 else 0 end),
          (if $l != $t then 1 else 0 end),
          ($l | tojson | @base64), ($t | tojson | @base64) ]
      | map(tostring) | join("\u001f")' "$tmp.json" 2>/dev/null)
  ARGOCD_DIFF_LABELONLY=$lo
  rm -f "$tmp.json" "$tmp.live" "$tmp.target"
  return 0
}

# _argocd_oos_rows <namespace> <batch> — rows (separator \x1f) in ARGOCD_ROWS:
# "app<S>name<S>count<S>url<S>app-namespace", "cdok<S>number of apps",
# "cdlogin", "cderr<S>text".
ARGOCD_ROWS=""
_argocd_oos_rows() {
  local S=$'\x1f' json rc sel
  sel=$(_argocd_selector "$1" "$2")
  ARGOCD_ROWS=""
  _argocd_apps_json "$sel"; rc=$?; json="$ARGOCD_JSON"
  if (( rc == 2 )); then ARGOCD_ROWS="cdlogin"; return 0; fi
  if (( rc != 0 )); then ARGOCD_ROWS="cderr${S}${ARGOCD_ERR}"; return 0; fi
  ARGOCD_ROWS=$(jq -r --arg S "$S" --arg base "https://${ARGOCD_SERVER}/applications" '
    (. // []) as $apps
    | ($apps | map(select(.status.sync.status == "OutOfSync"))) as $oos
    | if ($oos | length) == 0 then "cdok\($S)\($apps | length)"
      else $oos[] | "app\($S)\(.metadata.name)\($S)\([.status.resources[]? | select(.status == "OutOfSync")] | length)\($S)\($base)/\(.metadata.namespace)/\(.metadata.name)\($S)\(.metadata.namespace)"
      end' <<< "$json" 2>/dev/null) || ARGOCD_ROWS="cderr${S}jq parse error"
}

# ─── Approve from the terminal ───────────────────────────────────────
# argo_wf_approve <ns> <name> <batch|-> <url> <node> — submenu for a waiting
# workflow. Approving = resuming the suspended node, the same request the
# Resume button of the web UI sends (your name ends up in the node message).
argo_wf_approve() {
  local ns="$1" name="$2" batch="$3" url="$4" node="$5"
  [[ "$batch" == "-" ]] && batch=""
  UI_TITLE="Argo WF — ${name}"
  local what="${batch:+batch ${batch}}"; what="${what:-${node}}"
  local items="✔  Approve ${what} (resume ${node})
↗  Open in the browser"
  ui_select "$items" "wf" "${ns}/${name} is waiting: ${what} · Enter = select · Esc = back" || return 0
  case "$UI_RESULT" in
    "↗"*) _open_url "$url"; return 0 ;;
    "✔"*) ;;
    *) return 0 ;;
  esac
  # check once more that the workflow still sits on a suspend node
  _argo_wf_waiting "$ns" "$name"
  if [[ -z "$ARGO_WAIT" ]]; then
    section "Approval — ${ns}/${name}"
    sline "${YELLOW}⚠${NC}" "The workflow is no longer waiting (it moved on meanwhile) — nothing sent."
    pause_close; return 0
  fi
  local b="${ARGO_WAIT_BATCH:-$batch}" n="${ARGO_WAIT_NODE:-$node}"
  what="${b:+batch ${b}}"; what="${what:-${n}}"
  UI_TITLE="Approval — ${name}"
  ui_select "✖  No, go back
✔  Yes, approve ${what}" "confirm" \
    "PUT /api/v1/workflows/${ns}/${name}/resume (${n}) · Enter = select · Esc = back" || return 0
  [[ "$UI_RESULT" == "✔"* ]] || return 0
  # production batches (ARGO_WF_PROD_BATCHES) need the batch name typed out
  local pb
  for pb in $ARGO_WF_PROD_BATCHES; do
    if [[ -n "$b" && "$b" == "$pb" ]]; then
      UI_TITLE="PRODUCTION — ${name}"
      ui_input "type “${b}”" "Production batch — type its name (${b}) and press Enter to go ahead · Esc = back" || return 0
      if [[ "$UI_RESULT" != "$b" ]]; then
        section "Approval — ${ns}/${name}"
        sline "${YELLOW}⚠${NC}" "No match (“${UI_RESULT}” ≠ “${b}”) — cancelled, nothing sent."
        pause_close; return 0
      fi
    fi
  done
  local body
  body=$(jq -cn --arg n "$name" --arg ns "$ns" --arg sel "displayName=${n},phase=Running" \
    '{name: $n, namespace: $ns, nodeFieldSelector: $sel}')
  section "Approval — ${ns}/${name}"
  if _argo_api_put "/api/v1/workflows/${ns}/${name}/resume" "$body"; then
    sline "${GREEN}✔${NC}" "Approved — the workflow continues (${what})"
  else
    sline "${RED}✖${NC}" "Resume failed (HTTP ${ARGO_HTTP_CODE}): $(jq -r '.message // empty' <<< "$ARGO_BODY" 2>/dev/null || head -c 200 <<< "$ARGO_BODY")"
  fi
  pause_close
}

# ─── Building the table ──────────────────────────────────────────────
# _argo_prog <icon> <text> — progress line, only for a synchronous build
# (ARGO_PROGRESS=1); the background auto-refresh draws nothing.
_argo_prog() { (( ${ARGO_PROGRESS:-0} )) && sline "$1" "$2"; return 0; }

# _argo_ns_prefetch — downloads the lists of all namespaces in parallel into
# ARGO_PREFETCH_DIR; _argo_ns_rows then uses them instead of its own request.
ARGO_PREFETCH_DIR=""
_argo_ns_prefetch() {
  local ns pids=""
  ARGO_PREFETCH_DIR="${TMP_PREFIX}.ns.${RANDOM}"
  mkdir -p "$ARGO_PREFETCH_DIR"
  for ns in "${NAMESPACES[@]}"; do
    ( _argo_api "/api/v1/workflows/${ns}?listOptions.limit=${ARGO_WF_LIMIT}&fields=${ARGO_LIST_FIELDS}"
      printf '%s' "$ARGO_HTTP_CODE" > "${ARGO_PREFETCH_DIR}/${ns}.code"
      printf '%s' "$ARGO_BODY" > "${ARGO_PREFETCH_DIR}/${ns}.json" ) &
    pids+=" $!"
  done
  # shellcheck disable=SC2086
  wait $pids 2>/dev/null
}

# Changes of one resource are collected in dbuf; more than ARGOCD_DIFF_LINES
# of them collapse into a single "… N changes" row. Uses the caller's locals
# (recs, dbuf, dcount, S) — bash scoping is dynamic.
_argo_flush_diff() {
  if (( dcount == 0 )); then return; fi
  if (( dcount > ARGOCD_DIFF_LINES )); then
    recs+="cdchg${S}${S}more${S}${S}${S}${S}${S}… ${dcount} changes${S}__SKIP__"$'\n'
  else
    recs+="$dbuf"
  fi
  dbuf=""; dcount=0
}

# _argo_wf_build <outfile> — writes the table (rows for fzf) to outfile: first
# line "META <version> <running> <waiting> <config key>", then the list.
# rc 3 = 401 (a new token is needed). Bump ARGO_WF_CACHE_VER whenever the row
# or URL format changes — an older cache is then ignored at start-up.
ARGO_WF_CACHE_VER=4
_argo_wf_build() {
  local outfile="$1"
  local ns rows phase name age dur prog url total_running=0 total_waiting=0
  local recs="" kind note w_ns w_name list line S=$'\x1f'
  _argo_prog "${CYAN}▸${NC}" "Argo: ${NAMESPACES[*]} …"
  _argo_ns_prefetch
  for ns in "${NAMESPACES[@]}"; do
    url="${ARGO_WF_SERVER}/workflows/${ns}"
    if ! _argo_ns_rows "$ns"; then
      if [[ "$ARGO_HTTP_CODE" == "401" ]]; then rm -rf "$ARGO_PREFETCH_DIR" 2>/dev/null; return 3; fi
      _argo_prog "${RED}✖${NC}" "${ns}: HTTP ${ARGO_HTTP_CODE}"
      recs+="err${S}${ns}${S}${S}${S}${S}${S}${S}HTTP ${ARGO_HTTP_CODE}${S}${url}"$'\n'
      continue
    fi
    rows="$ARGO_ROWS"
    local running=0 last="" active=""
    while IFS=$'\t' read -r phase name age dur prog; do
      [[ -n "$name" ]] || continue
      case "$phase" in
        Running|Pending)
          running=$((running + 1))
          active+="${phase}"$'\t'"${name}"$'\t'"${age}"$'\t'"${dur}"$'\t'"${prog}"$'\n' ;;
        *)
          [[ -n "$last" ]] && continue
          case "$phase" in
            Succeeded)    last="${GREEN}✔${NC} ${age} ago" ;;
            Failed|Error) last="${RED}✖ ${phase}${NC} ${age} ago" ;;
            *)            last="${phase} ${age} ago" ;;
          esac ;;
      esac
    done <<< "$rows"
    total_running=$((total_running + running))
    _argo_prog "${GREEN}✔${NC}" "${ns}: ${running} running"

    if (( running == 0 )); then
      if [[ -z "$rows" ]]; then note="no workflows"
      else note="nothing running${last:+ · last ${last}}"; fi
      recs+="idle${S}${ns}${S}${S}${S}${S}${S}${S}${note}${S}${url}"$'\n'
      continue
    fi
    while IFS=$'\t' read -r phase name age dur prog; do
      [[ -n "$name" ]] || continue
      note=""; kind="run"
      if [[ "$phase" == "Running" ]]; then
        _argo_prog "${CYAN}▸${NC}" "${name}: nodes …"
        _argo_wf_waiting "$ns" "$name"
        if [[ -n "$ARGO_WAIT" ]]; then
          kind="wait"; note="$ARGO_WAIT"; total_waiting=$((total_waiting + 1))
          _argo_prog "${YELLOW}⏸${NC}" "${name}: ${ARGO_WAIT}"
        fi
      elif [[ "$phase" == "Pending" ]]; then
        kind="pend"
      fi
      local rowurl="${url}/${name}"
      [[ "$kind" == "wait" ]] && rowurl="__WAIT__ ${ns} ${name} ${ARGO_WAIT_BATCH:--} ${url}/${name} ${ARGO_WAIT_NODE}"
      recs+="${kind}${S}${ns}${S}${phase}${S}${name}${S}${age}${S}${dur}${S}${prog}${S}${note}${S}${rowurl}"$'\n'
      # under a waiting workflow: the Argo CD applications it is about to change
      if [[ "$kind" == "wait" ]] && argocd_enabled; then
        local batch="$ARGO_WAIT_BATCH" sel cdk cda cdb cdc cdd cd_real=0
        sel=$(_argocd_selector "$ns" "$batch")
        _argo_prog "${CYAN}▸${NC}" "Argo CD: ${sel} …"
        _argocd_oos_rows "$ns" "$batch"
        while IFS="$S" read -r cdk cda cdb cdc cdd; do
          [[ -n "$cdk" ]] || continue
          case "$cdk" in
            app)
              local drc dres dname dns dgroup dtype dtext dkey nreal
              _argo_prog "${CYAN}▸${NC}" "Argo CD diff: ${cda} …"
              _argocd_app_diff "$cda" "$cdd"; drc=$?
              if (( drc == 2 )); then
                recs+="cdlogin${S}${S}Argo CD${S}-${S}${S}${S}${S}not signed in · Enter = argocd login --sso${S}__ARGOCD_LOGIN__"$'\n'
                continue
              elif (( drc != 0 )); then
                recs+="cdapp${S}${S}OutOfSync${S}${cda}${S}${S}${S}${S}${cdb} out of sync · ${ARGOCD_ERR}${S}${cdc}"$'\n'
                continue
              fi
              nreal=$(grep -c "^res${S}" <<< "$ARGOCD_DIFF")
              # differences only in ignored keys (labels) = synced for our purposes
              (( nreal == 0 )) && continue
              cd_real=$((cd_real + 1))
              _argo_prog "${RED}↳${NC}" "${cda}: ${nreal} changed"
              recs+="cdapp${S}${S}OutOfSync${S}${cda}${S}${S}${S}${S}${nreal} changed${S}${cdc}"$'\n'
              # res<S>Kind/name<S>ns<S>group  |  chg<S>Kind/name<S>ns<S>group<S>add|del|chg<S>text
              # Diff rows cannot be selected (key __SKIP__, the arrows skip them).
              local dbuf="" dcount=0
              while IFS="$S" read -r dres dname dns dgroup dtype dtext; do
                [[ -n "$dres" ]] || continue
                if [[ "$dres" == "res" ]]; then
                  _argo_flush_diff
                  # Argo CD UI: the diff lives in the application panel
                  # (node=argoproj.io/Application/<ns>/<app>/0 + tab=diff);
                  # resource=kind:<Kind> narrows the tree to that kind
                  dkey="${cdc}?resource=kind%3A${dname%%/*}&node=$(printf '%s' "argoproj.io/Application/${cdd}/${cda}/0" | sed 's|/|%2F|g')&tab=diff"
                  recs+="cdres${S}${S}${S}${dname}${S}${S}${S}${S}${dns}${S}${dkey}"$'\n'
                  continue
                fi
                dcount=$((dcount + 1))
                dbuf+="cdchg${S}${S}${dtype}${S}${S}${S}${S}${S}${dtext}${S}__SKIP__"$'\n'
              done <<< "$ARGOCD_DIFF"
              _argo_flush_diff ;;
            cdlogin) recs+="cdlogin${S}${S}Argo CD${S}-${S}${S}${S}${S}not signed in · Enter = argocd login --sso${S}__ARGOCD_LOGIN__"$'\n' ;;
            cderr)   recs+="cderr${S}${S}Argo CD${S}-${S}${S}${S}${S}${cda}${S}"$'\n' ;;
          esac
        done <<< "$ARGOCD_ROWS"
        # nothing with real changes (all synced, or labels only) → one row
        if (( cd_real == 0 )) && [[ "$ARGOCD_ROWS" != cdlogin* && "$ARGOCD_ROWS" != cderr* ]]; then
          local selq="${sel//=/%3D}"; selq="${selq//,/%2C}"
          recs+="cdok${S}${S}Synced${S}-${S}${S}${S}${S}Argo CD: apps (${sel}) synced${S}https://${ARGOCD_SERVER}/applications?labels=${selq}"$'\n'
        fi
      fi
    done <<< "$active"
  done

  # Step 2: column widths (only ASCII fields are padded — bash printf counts
  # bytes, so the icon/color stay outside the padded text) and rendering.
  w_ns=9; w_name=8
  while IFS="$S" read -r kind ns phase name age dur prog note url; do
    [[ -n "$kind" ]] || continue
    (( ${#ns} > w_ns )) && w_ns=${#ns}
    [[ "$kind" == "cdres" ]] && name="   ${name}"
    (( ${#name} > w_name )) && w_name=${#name}
  done <<< "$recs"

  local fmt="%-${w_ns}s   %s %-9s   %-${w_name}s   %-11s  %-8s  %-6s  %s"
  list=$'\t'"$(printf '%b' "${DIM}$(printf "$fmt" "NAMESPACE" " " "STATE" "WORKFLOW" "STARTED" "DURATION" "PROG" "NOTE")${NC}")"$'\n'
  # rules across the whole panel (border + pointer = ~6 columns); inside
  # $(...) stdout is not a tty, so the size comes from stty on /dev/tty
  local rule rule_w
  rule_w=$({ stty size </dev/tty; } 2>/dev/null | awk '{print $2}')
  rule_w=$(( ${rule_w:-120} - 10 ))
  (( rule_w < w_ns + w_name + 62 )) && rule_w=$(( w_ns + w_name + 62 ))
  # first field "__RULE__" → the arrows skip the rule, Enter ignores it
  rule="__RULE__"$'\t'"$(printf '%b' "${DIM}$(printf '─%.0s' $(seq 1 "$rule_w"))${NC}")"$'\n'
  list+="$rule"
  list+=$'\t'"$(printf '%b' "${CYAN}↻ Refresh${NC}")"$'\n'
  while IFS="$S" read -r kind ns phase name age dur prog note url; do
    [[ -n "$kind" ]] || continue
    # a rule between workflows (not before the Argo CD sub-rows)
    case "$kind" in
      run|wait|pend|idle|err) list+="$rule" ;;
    esac
    local icon color
    case "$kind" in
      run)  icon="▶"; color="$CYAN";   phase="Running" ;;
      wait) icon="⏸"; color="$YELLOW"; phase="Waiting" ;;
      pend) icon="…"; color="$YELLOW"; phase="Pending" ;;
      err)  icon="✖"; color="$RED";    phase="Error";   note="${RED}${note}${NC}" ;;
      cdapp)   icon="↳"; color="$RED";    note="${RED}${note}${NC}" ;;
      cdres)   icon=" "; color="$DIM";    name="   ${name}"; note="${DIM}${note}${NC}" ;;
      cdok)    icon="↳"; color="$GREEN";  note="${DIM}${note}${NC}" ;;
      cdlogin) icon="↳"; color="$YELLOW"; note="${YELLOW}${note}${NC}" ;;
      cderr)   icon="↳"; color="$RED";    note="${RED}${note}${NC}" ;;
      cdchg)   ;;   # phase = add/del/chg/more, rendered below
      *)    icon="·"; color="$DIM";    phase="-"; name="-" ;;
    esac
    [[ "$kind" == "wait" ]] && note="${YELLOW}${note}${NC}"
    [[ "$kind" == "idle" ]] && note="${DIM}${note}${NC}"
    if [[ "$kind" == "cdchg" ]]; then
      # markers \x1c/\x1d … \x1e from _argocd_app_diff = exactly the changed
      # part: the whole old value red, the whole new value green (the key
      # uncolored), the changed part additionally inverse + bold (the way
      # diff-highlight / delta do it)
      local h_o=$'\x1c' h_n=$'\x1d' h_e=$'\x1e' h_old h_new
      local hl_r='\033[1;7;31m' hl_g='\033[1;7;32m'
      case "$phase" in
        add)  note="${note//$h_n/${hl_g}}"; note="${GREEN}+ ${note//$h_e/${GREEN}}${NC}" ;;
        del)  note="${note//$h_o/${hl_r}}"; note="${RED}- ${note//$h_e/${RED}}${NC}" ;;
        chg)  h_old="${note#*: }"; h_new="${h_old#* → }"; h_old="${h_old%% → *}"
              h_old="${h_old//$h_o/${hl_r}}"; h_old="${h_old//$h_e/${RED}}"
              h_new="${h_new//$h_n/${hl_g}}"; h_new="${h_new//$h_e/${GREEN}}"
              note="${note%%: *}: ${RED}${h_old}${YELLOW} → ${GREEN}${h_new}${NC}" ;;
        *)    note="${DIM}${note}${NC}" ;;
      esac
      line=$(printf "%-${w_ns}s   %s %-9s   %s" "" " " "" "      ${note}")
      list+="${url}"$'\t'"$(printf '%b' "$line")"$'\n'
      continue
    fi
    line=$(printf "$fmt" "$ns" "${color}${icon}${NC}" "$phase" "$name" "${age:+${age} ago}" "$dur" "$prog" "$note")
    # STATE in color: the padded text is wrapped only now (the pattern is
    # unique thanks to the icon's escape codes)
    line="${line/${color}${icon}${NC} ${phase}/${color}${icon} ${phase}${NC}}"
    list+="${url}"$'\t'"$(printf '%b' "$line")"$'\n'
  done <<< "$recs"

  printf 'META %s %s %s %s\n%s' "$ARGO_WF_CACHE_VER" "$total_running" "$total_waiting" "$CACHE_KEY" "${list%$'\n'}" > "$outfile"
  # cache for an instant start next time (shown at once, refreshed behind it)
  if [[ -n "${ARGO_WF_CACHE:-}" ]]; then
    mkdir -p "$(dirname "$ARGO_WF_CACHE")" 2>/dev/null
    cp "$outfile" "$ARGO_WF_CACHE" 2>/dev/null
  fi
  rm -rf "$ARGO_PREFETCH_DIR" 2>/dev/null
  return 0
}

# ─── The panel ───────────────────────────────────────────────────────
# _argo_wf_timer <tmp> <delay> — runs in the background while fzf is up:
# every second it redraws the countdown in the top border
# (change-border-label via --listen; title left, countdown right, ─ between)
# and when it runs out it builds a new table into $tmp.next and sends
# become(...). The refresh is postponed while the user is active: last
# movement/typing < ARGO_WF_IDLE s ago ($tmp.act, touched from the binds) or
# a filter is typed in (query from GET localhost:port).
_argo_wf_timer() {
  local tmp="$1" delay="$2" port="" deadline now rem cols left right fill label q act postponed=0
  # fzf picks the port (--listen=0), the start bind writes it to $tmp.port
  for _ in $(seq 1 50); do [[ -s "$tmp.port" ]] && break; sleep 0.1; done
  port=$(cat "$tmp.port" 2>/dev/null); [[ -n "$port" ]] || return 0
  deadline=$(( $(date +%s) + delay ))
  while true; do
    now=$(date +%s); rem=$(( deadline - now ))
    if (( rem <= 0 )); then
      act=$(_mtime "$tmp.act")
      q=$(curl -s -m 1 "localhost:${port}" 2>/dev/null | jq -r '.query // ""' 2>/dev/null)
      if (( now - act < ARGO_WF_IDLE )) || [[ -n "$q" ]]; then
        postponed=1; deadline=$(( now + ARGO_WF_IDLE ))   # the user is busy → wait
      else
        if ARGO_PROGRESS=0 _argo_wf_build "$tmp.next.tmp"; then mv "$tmp.next.tmp" "$tmp.next"
        elif (( $? == 3 )); then : > "$tmp.401"; fi
        curl -s -m 2 -XPOST "localhost:${port}" -d 'become(echo "__REFRESH__ {n}")' >/dev/null 2>&1
        return 0
      fi
    fi
    cols=$({ stty size </dev/tty; } 2>/dev/null | awk '{print $2}'); cols=${cols:-120}
    left=" ${UI_TITLE} "
    if (( postponed )); then right=" ↻ waiting until you are idle "
    else right=" ↻ $(printf '%d:%02d' $(( rem / 60 )) $(( rem % 60 ))) "; fi
    fill=$(( cols - 2 - ${#left} - ${#right} ))
    (( fill < 1 )) && fill=1
    label="${left}$(printf '─%.0s' $(seq 1 "$fill"))${right}"
    curl -s -m 1 -XPOST "localhost:${port}" -d "change-border-label:${label}" >/dev/null 2>&1
    sleep 1
  done
}

TMP_PREFIX="${TMPDIR:-/tmp}/argo-wf.$$"
TIMER_PID=""

_timer_stop() {
  [[ -n "$TIMER_PID" ]] || return 0
  pkill -P "$TIMER_PID" 2>/dev/null; kill "$TIMER_PID" 2>/dev/null; wait "$TIMER_PID" 2>/dev/null
  TIMER_PID=""
}

cleanup() {
  _timer_stop
  if [[ -n "$STTY_SAVED" ]]; then stty "$STTY_SAVED" </dev/tty 2>/dev/null; printf '\033[?25h'; fi
  rm -rf "$TMP_PREFIX".* 2>/dev/null
}

argo_wf_status() {
  local title="Argo WF · ${ARGO_WF_SERVER#http*://}"
  # the token is verified up front only when there is none at all; an expired
  # one is caught by the build (401)
  [[ -n "${ARGO_TOKEN:-}" ]] || argo_wf_ensure_token || return 0

  # auto-refresh: a background timer builds the new table into $tmp.next (the
  # panel stays on screen meanwhile) and then tells the running fzf (--listen)
  # become(...) → fzf exits with "__REFRESH__ <cursor index>", the loop just
  # loads the finished table and puts the cursor back on the same row.
  local cursor=0 url reuse=0 sel
  local tmp="$TMP_PREFIX" meta list total_running total_waiting rc
  rm -rf "$tmp".* 2>/dev/null
  # quick start: the last table from the cache is shown at once (marked as
  # old) and the timer refreshes it in the background without delay
  ARGO_WF_CACHE="${CACHE_DIR}/table-${CACHE_KEY}"
  local stale=0 stale_note=""
  if [[ -f "$ARGO_WF_CACHE" ]] && head -1 "$ARGO_WF_CACHE" | grep -q "^META ${ARGO_WF_CACHE_VER} [0-9]* [0-9]* ${CACHE_KEY}\$"; then
    cp "$ARGO_WF_CACHE" "$tmp.next"; stale=1
  fi
  # leftovers of instances that died without cleanup (closed terminal)
  local f fpid
  for f in "${TMPDIR:-/tmp}"/argo-wf.*; do
    [[ -e "$f" ]] || continue
    fpid="${f##*/argo-wf.}"; fpid="${fpid%%.*}"
    [[ "$fpid" =~ ^[0-9]+$ ]] && ! kill -0 "$fpid" 2>/dev/null && rm -rf "$f"
  done
  while true; do
    if (( reuse )); then
      reuse=0                      # Enter = a URL was opened: the table stays, nothing is fetched
    elif [[ -f "$tmp.next" ]]; then
      mv "$tmp.next" "$tmp.cur"
    else
      stale=0
      section "Argo WF — loading …"
      ARGO_PROGRESS=1 _argo_wf_build "$tmp.cur"; rc=$?
      if (( rc == 3 )); then argo_wf_ensure_token force || return 0; continue; fi
    fi
    stale_note=""
    (( stale )) && stale_note=" · ${YELLOW}data from $(date -r "$ARGO_WF_CACHE" +%H:%M), refreshing…${NC}"
    if [[ -f "$tmp.401" ]]; then
      rm -f "$tmp.401"
      argo_wf_ensure_token force || return 0
      continue
    fi
    meta=$(head -1 "$tmp.cur"); list=$(tail -n +2 "$tmp.cur")
    # shellcheck disable=SC2086
    set -- $meta; total_running="${3:-0}"; total_waiting="${4:-0}"

    rm -f "$tmp.port" "$tmp.act"
    # The arrows skip rows that cannot be selected (rules __RULE__, diff rows
    # __SKIP__): after a move a transform runs the nav script, which for such
    # a row returns another move + the same transform (recursion) and turns
    # around at either end of the list.
    # {n} = 0-based index without header rows, pos() = 1-based.
    local count
    count=$(( $(printf '%s\n' "$list" | wc -l | tr -d ' ') - 2 ))
    cat > "$tmp.nav.sh" <<'NAV'
dir="$1" n="$2" total="$3" line="$4"
case "$line" in __RULE__*|__SKIP__*) ;; *) exit 0 ;; esac
if [[ "$dir" == down && "$n" -ge $(( total - 1 )) ]]; then dir=up; fi
if [[ "$dir" == up && "$n" -le 0 ]]; then dir=down; fi
printf '%s+transform:bash %s %s {n} %s {}' "$dir" "$0" "$dir" "$total"
NAV
    UI_EXTRA_OPTS=(--ansi --delimiter=$'\t' --with-nth=2.. --no-sort --header-lines=2
                   "--bind=load:pos($(( cursor + 1 )))"
                   "--bind=down:down+transform:bash '$tmp.nav.sh' down {n} $count {}"
                   "--bind=up:up+transform:bash '$tmp.nav.sh' up {n} $count {}"
                   "--bind=enter:become(echo {n}; echo {})")   # line 1 = cursor index, line 2 = the selected row
    local auto="" delay="$ARGO_WF_REFRESH"
    (( stale )) && delay=0
    UI_TITLE="$title"
    if (( ARGO_WF_REFRESH > 0 || stale )); then
      # --listen=0 = a random free port (fzf exposes it as $FZF_PORT); activity
      # (arrows, typing) touches $tmp.act → the refresh is postponed
      UI_EXTRA_OPTS+=(--listen=0
                      "--bind=start:execute-silent(echo \$FZF_PORT > '$tmp.port')"
                      "--bind=up:+execute-silent(touch '$tmp.act')"
                      "--bind=down:+execute-silent(touch '$tmp.act')"
                      "--bind=change:execute-silent(touch '$tmp.act')")
      if (( ARGO_WF_REFRESH >= 60 )); then auto=" · auto-refresh $(( ARGO_WF_REFRESH / 60 )) min"
      elif (( ARGO_WF_REFRESH > 0 )); then auto=" · auto-refresh ${ARGO_WF_REFRESH} s"; fi
      ( _argo_wf_timer "$tmp" "$delay" ) 2>/dev/null &   # no stderr: a killed subshell would print "Terminated"
      TIMER_PID=$!
    fi
    ui_select "$list" "argo" \
      "$(printf '%b' "running: ${total_running} · waiting: ${total_waiting}${auto}${stale_note} · Enter = open / approve / refresh · Esc = quit")"
    rc=$?
    _timer_stop
    (( rc == 0 )) || return 0
    if [[ "$UI_RESULT" == __REFRESH__* ]]; then
      cursor="${UI_RESULT#__REFRESH__ }"; [[ "$cursor" =~ ^[0-9]+$ ]] || cursor=0
      stale=0
      continue
    fi
    stale=0
    rm -f "$tmp.next" "$tmp.next.tmp"
    sel="${UI_RESULT%%$'\n'*}"; [[ "$sel" =~ ^[0-9]+$ ]] || sel=0
    UI_RESULT="${UI_RESULT#*$'\n'}"
    url="${UI_RESULT%%$'\t'*}"
    cursor="$sel"
    if [[ "$url" == "__RULE__" || "$url" == "__SKIP__" ]]; then reuse=1; continue; fi
    if [[ "$url" == "__ARGOCD_LOGIN__" ]]; then argocd_login; continue; fi
    if [[ "$url" == __WAIT__* ]]; then
      # shellcheck disable=SC2086
      set -- $url; argo_wf_approve "$2" "$3" "$4" "$5" "${*:6}"; continue
    fi
    if [[ -z "$url" ]]; then cursor=0; continue; fi   # Refresh → a new table
    _open_url "$url"; reuse=1
  done
}

# ─── Command line ────────────────────────────────────────────────────
usage() {
  cat <<EOF
argo-wf ${VERSION} — terminal dashboard for Argo Workflows

Usage: ${0##*/} [options]

  -s, --server URL         Argo Workflows server (https://argo.example.com)
  -n, --namespaces "A B"   namespaces to watch (space or comma separated)
      --argocd HOST        Argo CD server for the out-of-sync view ("" = off)
  -c, --config FILE        config file (default: ${CONFIG_FILE/#$HOME/~})
      --setup              ask for server / namespaces / Argo CD again
      --logout             forget the saved token
  -h, --help               this help
  -V, --version            print the version

Settings are remembered in the config file; every option also exists as an
environment variable (ARGO_WF_SERVER, ARGO_WF_NAMESPACES, ARGOCD_SERVER, …).
Tunables: ARGO_WF_REFRESH (s, 0 = off), ARGO_WF_LIMIT, ARGO_WF_PROD_BATCHES,
ARGO_WF_INSECURE=1, ARGOCD_SELECTOR, ARGOCD_DIFF_LINES, ARGOCD_DIFF_IGNORE.
EOF
}

check_deps() {
  local dep missing=""
  for dep in fzf curl jq; do
    command -v "$dep" >/dev/null || missing+=" $dep"
  done
  if [[ -n "$missing" ]]; then
    err "Missing:${missing} — install with e.g. 'brew install${missing}' or your package manager."
    exit 1
  fi
  local v major minor
  v=$(fzf --version | awk '{print $1}')
  major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
  if [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] && (( major == 0 && minor < 45 )); then
    err "fzf ${v} is too old — 0.45 or newer is needed (distribution packages lag; see https://github.com/junegunn/fzf#installation)."
    exit 1
  fi
  if ! { : </dev/tty; } 2>/dev/null; then
    err "No terminal — this is an interactive tool."
    exit 1
  fi
}

main() {
  local opt_server="" opt_ns="" opt_argocd="" has_argocd=0 do_setup=0 do_logout=0
  while (( $# )); do
    case "$1" in
      -s|--server)     opt_server="${2:-}"; shift 2 || { usage; exit 2; } ;;
      -n|--namespaces) opt_ns="${2:-}"; shift 2 || { usage; exit 2; } ;;
      --argocd)        opt_argocd="${2:-}"; has_argocd=1; shift 2 || { usage; exit 2; } ;;
      -c|--config)     CONFIG_FILE="${2:-}"; shift 2 || { usage; exit 2; } ;;
      --setup)         do_setup=1; shift ;;
      --logout)        do_logout=1; shift ;;
      -h|--help)       usage; exit 0 ;;
      -V|--version)    echo "argo-wf ${VERSION}"; exit 0 ;;
      *)               err "Unknown option: $1"; usage; exit 2 ;;
    esac
  done
  if (( do_logout )); then
    config_unset ARGO_TOKEN
    ok "Token removed from ${CONFIG_FILE/#$HOME/~}"
    exit 0
  fi

  check_deps
  trap cleanup EXIT
  trap 'exit 130' INT TERM HUP

  config_load
  [[ -n "$opt_server" ]] && ARGO_WF_SERVER="$opt_server"
  [[ -n "$opt_ns" ]] && ARGO_WF_NAMESPACES="$opt_ns"
  (( has_argocd )) && ARGOCD_SERVER="$opt_argocd"
  config_apply
  # what came on the command line is remembered for the next plain start
  [[ -n "$opt_server" ]] && config_set ARGO_WF_SERVER "$ARGO_WF_SERVER"
  [[ -n "$opt_ns" ]] && config_set ARGO_WF_NAMESPACES "${NAMESPACES[*]}"
  (( has_argocd )) && config_set ARGOCD_SERVER "$ARGOCD_SERVER"

  if (( do_setup )) || [[ -z "$ARGO_WF_SERVER" || ${#NAMESPACES[@]} -eq 0 ]]; then
    if ! setup_wizard; then
      clear
      [[ -n "$ARGO_WF_SERVER" && ${#NAMESPACES[@]} -gt 0 ]] || { err "Setup cancelled — a server and at least one namespace are needed."; exit 1; }
    fi
  fi

  argo_wf_status
  clear
}

main "$@"
