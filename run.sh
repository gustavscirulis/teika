#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

DERIVED_DATA="$PWD/DerivedData"
STATE_FILE="$PWD/.run-last-destination"
TARGET_STATE_FILE="$PWD/.run-last-target"

# One picker, both platforms. The Teika scheme embeds the watch app but installs
# only the phone app, so running on a watch needs the other scheme — which scheme
# to build is decided by the destination you pick rather than by a flag.
#   scheme | bundle id | simulator product dir | device product dir
TARGETS=(
  "Teika|com.gustavscirulis.teika|iphonesimulator|iphoneos"
  "TeikaWatch|com.gustavscirulis.teika.watchkitapp|watchsimulator|watchos"
)

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
  GREEN=$'\033[32m'; CYAN=$'\033[36m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; BLUE=$'\033[34m'
else
  BOLD=""; DIM=""; RESET=""; GREEN=""; CYAN=""; YELLOW=""; RED=""; BLUE=""
fi

step() { printf "\n${BOLD}${BLUE}➜${RESET} ${BOLD}%s${RESET}\n" "$1"; }
ok()   { printf "${GREEN}✓${RESET} %s\n" "$1"; }
die()  { printf "${RED}✗ %s${RESET}${RESET}\n" "$1" >&2; exit 1; }

banner() {
  printf "\n${BOLD}${CYAN}┌───────────────────────────────┐${RESET}\n"
  printf "${BOLD}${CYAN}│${RESET}  ${BOLD}🦜 Teika${RESET} ${DIM}· %-20s${RESET}${BOLD}${CYAN}│${RESET}\n" "$1"
  printf "${BOLD}${CYAN}└───────────────────────────────┘${RESET}\n"
}

badge_for() { # $1 = platform, $2 = sim|device
  local glyph
  [[ "$1" == "watchOS" ]] && glyph="⌚" || glyph="📱"
  if [[ "$2" == "device" ]]; then
    printf "%s%s device%s" "$YELLOW" "$glyph" "$RESET"
  else
    printf "%s%s sim   %s" "$CYAN" "$glyph" "$RESET"
  fi
}

usage() {
  cat <<EOF

${BOLD}Usage${RESET}
  ./run.sh                      Pick what to run, then how
  ./run.sh app [destination]    Build and run the iOS app
  ./run.sh site [mode]          Run the website in site/
  ./run.sh <destination>        Shorthand for: app <destination>
  ./run.sh --help               This text

${BOLD}App destinations${RESET}
  With no argument an arrow-key picker lists every simulator and device.
  Pass a name or id to skip it, e.g. ./run.sh "iPhone 17 Pro".

${BOLD}Site modes${RESET}
  dev        Next dev server with hot reload (default)
  build      Static export into site/out
  preview    Static export, then serve it exactly as it will ship

${BOLD}Environment${RESET}
  SITE_PORT            dev server port (default 3000)
  SITE_PREVIEW_PORT    preview server port (default 4321)
  TEIKA_DEVELOPMENT_TEAM
                       Apple Developer Team ID for physical-device signing

The last target and the last iOS destination are remembered and preselected.

EOF
}

# ── Arrow-key menu ───────────────────────────────────────────────────────────
# Three parallel arrays rather than one pre-rendered string per row, so the
# highlight can colour the name while leaving the badge its own colour — and so
# this stays inside what the bash 3.2 that ships with macOS understands.
MENU_BADGES=(); MENU_NAMES=(); MENU_TAGS=(); MENU_PICK=""

menu_reset() { MENU_BADGES=(); MENU_NAMES=(); MENU_TAGS=(); MENU_PICK=""; }
menu_add()   { MENU_BADGES+=("$1"); MENU_NAMES+=("$2"); MENU_TAGS+=("${3:-}"); }

draw_menu() {
  local cur="$1" first="$2" i
  [[ "$first" == "1" ]] || printf '\033[%dA' "${#MENU_NAMES[@]}"
  for i in "${!MENU_NAMES[@]}"; do
    printf '\r\033[K'
    if [[ "$i" == "$cur" ]]; then
      printf "  ${GREEN}${BOLD}▸${RESET} %b  ${GREEN}${BOLD}%b${RESET}%b\n" \
        "${MENU_BADGES[$i]}" "${MENU_NAMES[$i]}" "${MENU_TAGS[$i]}"
    else
      printf "    %b  %b%b\n" "${MENU_BADGES[$i]}" "${MENU_NAMES[$i]}" "${MENU_TAGS[$i]}"
    fi
  done
}

menu_select() {
  local cur="${1:-0}" count="${#MENU_NAMES[@]}" key rest
  printf "${DIM}Use ↑/↓ to move, Enter to select${RESET}\n\n"
  printf '\033[?25l'
  draw_menu "$cur" 1
  while true; do
    IFS= read -rsn1 key
    if [[ "$key" == $'\033' ]]; then
      IFS= read -rsn2 -t 1 rest || true
      key+="$rest"
    fi
    case "$key" in
      $'\033[A' | k) ((cur > 0)) && ((cur--)) || cur=$((count - 1)) ;;
      $'\033[B' | j) ((cur < count - 1)) && ((cur++)) || cur=0 ;;
      "" | $'\n' | $'\r') break ;;
      q) printf '\033[?25h'; die "Cancelled." ;;
    esac
    draw_menu "$cur" 0
  done
  printf '\033[?25h'
  MENU_PICK="$cur"
}

# ── Website ──────────────────────────────────────────────────────────────────
run_site() {
  local mode="$1"
  local dir="$PWD/site"

  [[ -d "$dir" ]] || die "No site/ directory here. Expected $dir"
  command -v npm >/dev/null 2>&1 || die "npm not found. Install Node.js to run the site."

  if [[ ! -d "$dir/node_modules" ]]; then
    step "Installing dependencies"
    (cd "$dir" && npm install)
    ok "Dependencies installed"
  fi

  case "$mode" in
    dev)
      local port="${SITE_PORT:-3000}"
      step "Starting dev server on port $port"
      printf "${DIM}Hot reload is on. Ctrl-C to stop.${RESET}\n"
      # Give Next a moment to bind before the browser races it.
      ( sleep 2.5; open "http://localhost:$port" >/dev/null 2>&1 || true ) &
      cd "$dir"
      exec npm run dev -- --port "$port"
      ;;

    build)
      step "Building static export"
      (cd "$dir" && npm run build)
      # GitHub Pages refuses to serve _next/ without this.
      touch "$dir/out/.nojekyll"
      ok "Static site in site/out ($(du -sh "$dir/out" | cut -f1))"
      printf "\n${DIM}Deploy notes are in site/README.md${RESET}\n\n"
      ;;

    preview)
      local port="${SITE_PREVIEW_PORT:-4321}"
      step "Building static export"
      (cd "$dir" && npm run build)
      touch "$dir/out/.nojekyll"
      ok "Build succeeded"

      step "Serving site/out on port $port"
      printf "${DIM}The real static export, not the dev server. Ctrl-C to stop.${RESET}\n"
      ( sleep 1.5; open "http://localhost:$port" >/dev/null 2>&1 || true ) &
      cd "$dir/out"
      # python3 ships with macOS and redirects /privacy to /privacy/, which is
      # what `trailingSlash: true` emits. npx serve is the fallback.
      if command -v python3 >/dev/null 2>&1; then
        exec python3 -m http.server "$port" --bind 127.0.0.1
      else
        exec npx --yes serve . -l "$port"
      fi
      ;;

    *)
      die "Unknown site mode '$mode'. Expected dev, build or preview."
      ;;
  esac
}

pick_site_mode() {
  menu_reset
  menu_add "${CYAN}dev    ${RESET}" "Dev server"       " ${DIM}· hot reload, opens a browser${RESET}"
  menu_add "${CYAN}build  ${RESET}" "Static export"    " ${DIM}· writes site/out${RESET}"
  menu_add "${CYAN}preview${RESET}" "Serve the export" " ${DIM}· exactly as it will ship${RESET}"
  echo
  menu_select 0
  case "$MENU_PICK" in
    0) SITE_MODE="dev" ;;
    1) SITE_MODE="build" ;;
    2) SITE_MODE="preview" ;;
  esac
}

# ── iOS app ──────────────────────────────────────────────────────────────────
# xcodebuild resolves the entire Swift package graph before it will name a
# scheme's destinations, and left to itself that means a network fetch of every
# remote package on every launch: two and a half minutes when GitHub is healthy,
# an open-ended stall when it is not — all of it hidden behind "Discovering
# destinations", because the old call sent stderr to /dev/null. The picker only
# needs the list of simulators, so pin resolution to Package.resolved and the
# clone cache and leave the network to the build.
PINNED_PACKAGES=(
  -disableAutomaticPackageResolution
  -onlyUsePackageVersionsFromResolvedFile
  -skipPackageUpdates
)
DEST_TIMEOUT=120

list_destinations() { # $1 = scheme, $2 = file to fill with -showdestinations output
  local scheme="$1" out="$2" err pid watchdog rc=0
  err="$(mktemp)"

  xcodebuild -project Teika.xcodeproj -scheme "$scheme" -showdestinations \
    -derivedDataPath "$DERIVED_DATA" "${PINNED_PACKAGES[@]}" \
    >"$out" 2>"$err" </dev/null &
  pid=$!
  # Off the network this is a couple of seconds, so a long wait means something
  # is wedged — usually CoreSimulator. Say so rather than sit on the spinner.
  ( sleep "$DEST_TIMEOUT"; kill -TERM "$pid" 2>/dev/null ) &
  watchdog=$!
  # 2>/dev/null: when the watchdog fires, bash would otherwise announce the kill
  # ("Terminated: 15") on top of the message we are about to print.
  wait "$pid" 2>/dev/null || rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true

  if [[ "$rc" == 143 ]]; then
    rm -f "$err"
    die "Listing destinations for $scheme gave up after ${DEST_TIMEOUT}s. Check 'xcrun simctl list devices'."
  fi

  if [[ "$rc" == 0 ]] && grep -q "{ platform:" "$out"; then
    rm -f "$err"
    return 0
  fi

  # First run on a fresh checkout, or a package version just moved: there is no
  # Package.resolved to pin to. Resolve for real, but visibly — this is the path
  # that takes minutes, and it should look like it is doing something.
  printf "${YELLOW}⚠${RESET} The package cache was not enough for %s. Resolving from the network:\n" "$scheme"
  sed -E 's/^/  /' "$err" >&2
  rm -f "$err"
  if ! xcodebuild -project Teika.xcodeproj -scheme "$scheme" -showdestinations \
       -derivedDataPath "$DERIVED_DATA" </dev/null 2>&1 | tee "$out"; then
    die "xcodebuild could not list destinations for $scheme."
  fi
}

run_app() {
  local query="${1:-}"

  step "Generating Teika.xcodeproj from project.yml"
  # XcodeGen locates its SettingPresets relative to the binary it was *invoked* as, so
  # running it through a symlink (e.g. /opt/homebrew/bin -> ~/.local) silently drops
  # every preset: no DEBUG flag, no release optimisation, no ONLY_ACTIVE_ARCH. Resolve
  # the symlink chain first so the generated project is the same everywhere.
  local XCODEGEN target
  XCODEGEN="$(command -v xcodegen)" || die "xcodegen not found."
  while [[ -L "$XCODEGEN" ]]; do
    target="$(readlink "$XCODEGEN")"
    [[ "$target" = /* ]] || target="$(dirname "$XCODEGEN")/$target"
    XCODEGEN="$target"
  done
  "$XCODEGEN" generate >/dev/null
  grep -q SWIFT_ACTIVE_COMPILATION_CONDITIONS Teika.xcodeproj/project.pbxproj \
    || die "XcodeGen produced a project without its setting presets (DEBUG would be undefined)."
  ok "Project generated"

  step "Discovering destinations"
  local -a NAMES IDS TYPES PLATFORMS SCHEMES BUNDLES PRODUCT_DIRS
  NAMES=(); IDS=(); TYPES=(); PLATFORMS=(); SCHEMES=(); BUNDLES=(); PRODUCT_DIRS=()
  local entry scheme bundle sim_dir device_dir file line plat type platform id name os
  # One scheme at a time: run concurrently they fight over the same package
  # clone cache, and a lost race leaves it corrupt ("could not open
  # objects/pack/tmp_pack_… for reading"), which then fails every later run.
  for entry in "${TARGETS[@]}"; do
    IFS='|' read -r scheme bundle sim_dir device_dir <<<"$entry"
    file="$(mktemp)"
    list_destinations "$scheme" "$file"
    while IFS= read -r line; do
      [[ "$line" == *"{ platform:"* ]] || continue
      [[ "$line" == *placeholder* ]] && continue
      plat="$(sed -E 's/.*platform:([^,}]*).*/\1/' <<<"$line" | sed -E 's/[[:space:]]+$//')"
      case "$plat" in
        macOS) continue ;;
        *Simulator*) type="sim" ;;
        *) type="device" ;;
      esac
      case "$plat" in
        watchOS*) platform="watchOS" ;;
        *) platform="iOS" ;;
      esac
      id="$(sed -E 's/.*[,{ ]id:([^,}]*).*/\1/' <<<"$line" | sed -E 's/[[:space:]]+$//')"
      name="$(sed -E 's/.*name:([^,}]*).*/\1/' <<<"$line" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
      os="$(grep -oE 'OS:[^,}]*' <<<"$line" | sed -E 's/OS://;s/[[:space:]]//g' || true)"
      [[ -n "$os" ]] && name="$name ${DIM}($os)${RESET}"
      NAMES+=("$name")
      IDS+=("$id")
      TYPES+=("$type")
      PLATFORMS+=("$platform")
      SCHEMES+=("$scheme")
      BUNDLES+=("$bundle")
      [[ "$type" == "sim" ]] && PRODUCT_DIRS+=("Debug-$sim_dir") || PRODUCT_DIRS+=("Debug-$device_dir")
    done <"$file"
    rm -f "$file"
  done

  [[ ${#IDS[@]} -gt 0 ]] || die "No simulators or devices found."
  ok "Found ${#IDS[@]} destination(s)"

  local last_id="" default_idx="" i
  [[ -f "$STATE_FILE" ]] && last_id="$(cat "$STATE_FILE")"
  for i in "${!IDS[@]}"; do
    [[ "${IDS[$i]}" == "$last_id" ]] && default_idx="$i"
  done

  local pick=""
  if [[ -n "$query" ]]; then
    for i in "${!IDS[@]}"; do
      if [[ "${IDS[$i]}" == "$query" ]] || [[ "${NAMES[$i]}" == *"$query"* ]]; then
        pick="$i"; break
      fi
    done
    [[ -n "$pick" ]] || die "No destination matched '$query'."
  elif [[ -t 0 ]]; then
    menu_reset
    for i in "${!IDS[@]}"; do
      local badge tag=""
      badge="$(badge_for "${PLATFORMS[$i]}" "${TYPES[$i]}")"
      [[ "$i" == "$default_idx" ]] && tag=" ${DIM}· last used${RESET}"
      menu_add "$badge" "${NAMES[$i]}" "$tag"
    done
    echo
    menu_select "${default_idx:-0}"
    pick="$MENU_PICK"
  else
    pick="${default_idx:-0}"
  fi

  local DEST_ID="${IDS[$pick]}" DEST_TYPE="${TYPES[$pick]}"
  local SCHEME="${SCHEMES[$pick]}" BUNDLE_ID="${BUNDLES[$pick]}" PRODUCT_DIR="${PRODUCT_DIRS[$pick]}"
  printf "%s" "$DEST_ID" >"$STATE_FILE"

  local -a FORMAT
  if command -v xcbeautify >/dev/null 2>&1; then
    FORMAT=(xcbeautify)
  else
    FORMAT=(cat)
  fi

  local -a SIGNING_ARGS
  SIGNING_ARGS=()
  if [[ "$DEST_TYPE" == "device" ]]; then
    [[ -n "${TEIKA_DEVELOPMENT_TEAM:-}" ]] ||
      die "Set TEIKA_DEVELOPMENT_TEAM to your Apple Developer Team ID for a physical-device build."
    SIGNING_ARGS=("DEVELOPMENT_TEAM=$TEIKA_DEVELOPMENT_TEAM" -allowProvisioningUpdates)
  fi

  step "Building $SCHEME for ${NAMES[$pick]}"
  xcodebuild \
    -project Teika.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "id=$DEST_ID" \
    -derivedDataPath "$DERIVED_DATA" \
    "${SIGNING_ARGS[@]}" \
    build \
    | "${FORMAT[@]}"
  ok "Build succeeded"

  local APP
  APP="$(find "$DERIVED_DATA/Build/Products/$PRODUCT_DIR" -maxdepth 1 -name "$SCHEME.app" | head -1)"
  [[ -n "$APP" ]] || die "Could not locate built .app under $DERIVED_DATA/Build/Products/$PRODUCT_DIR"

  if [[ "$DEST_TYPE" == "sim" ]]; then
    step "Installing & launching on simulator"
    xcrun simctl boot "$DEST_ID" 2>/dev/null || true
    open -a Simulator
    xcrun simctl install "$DEST_ID" "$APP"
    xcrun simctl launch "$DEST_ID" "$BUNDLE_ID" >/dev/null
  else
    step "Installing & launching on device"
    xcrun devicectl device install app --device "$DEST_ID" "$APP"
    xcrun devicectl device process launch --device "$DEST_ID" "$BUNDLE_ID"
  fi

  printf "\n${GREEN}${BOLD}🚀 Launched Teika${RESET}\n\n"
}

# ── What are we running? ─────────────────────────────────────────────────────
TARGET=""
SITE_MODE=""
DEST_QUERY=""

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  site)           TARGET="site"; SITE_MODE="${2:-}" ;;
  app)            TARGET="app";  DEST_QUERY="${2:-}" ;;
  "")             ;;
  *)              TARGET="app";  DEST_QUERY="$1" ;;
esac

banner "build & run"

# The target picker comes before XcodeGen on purpose: choosing the website
# should never cost an Xcode project regeneration and a simulator enumeration.
if [[ -z "$TARGET" ]]; then
  last_target=""
  [[ -f "$TARGET_STATE_FILE" ]] && last_target="$(cat "$TARGET_STATE_FILE")"

  if [[ -t 0 ]]; then
    menu_reset
    app_tag=""; site_tag=""
    [[ "$last_target" == "app"  ]] && app_tag=" ${DIM}· last used${RESET}"
    [[ "$last_target" == "site" ]] && site_tag=" ${DIM}· last used${RESET}"
    menu_add "${CYAN}📱 app   ${RESET}" "iOS app" "$app_tag"
    menu_add "${CYAN}🌐 site  ${RESET}" "Website" "$site_tag"
    echo
    menu_select "$([[ "$last_target" == "site" ]] && echo 1 || echo 0)"
    [[ "$MENU_PICK" == "1" ]] && TARGET="site" || TARGET="app"
  else
    TARGET="${last_target:-app}"
  fi
fi

printf "%s" "$TARGET" >"$TARGET_STATE_FILE"

if [[ "$TARGET" == "site" ]]; then
  if [[ -z "$SITE_MODE" ]]; then
    if [[ -t 0 ]]; then
      pick_site_mode
    else
      SITE_MODE="dev"
    fi
  fi
  run_site "$SITE_MODE"
else
  run_app "$DEST_QUERY"
fi
