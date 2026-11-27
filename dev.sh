#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
ENV_EXAMPLE_FILE="${ROOT_DIR}/.env.example"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"
CERT_DIR="${ROOT_DIR}/docker/caddy/certs"
CERT_FILE="${CERT_DIR}/caddy-local-root.crt"
CERT_RENEW_WINDOW_SEC=86400

# ------------------------------------------------------------------------------
# Helpers & Environment
# ------------------------------------------------------------------------------

#-----------------------------------------
# Print an informational message prefixed with [dev.sh] to stdout.
#
# @param  string $* Message text.
# @stdout Formatted informational line.
# @return void
#-----------------------------------------
log_info() {
  printf '[dev.sh] %s\n' "$*"
}

#-----------------------------------------
# Print a warning message prefixed with [dev.sh] WARNING to stderr.
#
# @param  string $* Warning text.
# @stderr Formatted warning line.
# @return void
#-----------------------------------------
log_warn() {
  printf '[dev.sh] WARNING: %s\n' "$*" >&2
}

#-----------------------------------------
# Print an error message prefixed with [dev.sh] ERROR to stderr.
#
# @param  string $* Error text.
# @stderr Formatted error line.
# @return void
#-----------------------------------------
log_err() {
  printf '[dev.sh] ERROR: %s\n' "$*" >&2
}

#-----------------------------------------
# Log an error message and exit the script with status 1.
#
# @param  string $* Fatal error text.
# @stderr Formatted error line.
# @return never Exits with code 1.
#-----------------------------------------
die() {
  log_err "$*"
  exit 1
}

#-----------------------------------------
# Load environment variables from .env, creating it from .env.example if absent.
# Pass '--optional' to skip creating .env and fall back to defaults when no env
# files exist (used by standalone commands such as help and commit-msg).
#
# @param  string $1 Optional '--optional' flag to allow running without .env/.env.example.
# @global string ENV_FILE Path to the project .env file.
# @global string ENV_EXAMPLE_FILE Path to the .env.example template.
# @global string PROJECT Docker Compose project and container prefix.
# @global string DOMAIN Local HTTPS domain served by Caddy.
# @global string HTTP_PORT Host HTTP port.
# @global string HTTPS_PORT Host HTTPS port.
# @global string POSTGRES_DB PostgreSQL database name.
# @global string POSTGRES_USER PostgreSQL username.
# @global string POSTGRES_PASSWORD PostgreSQL password.
# @return void
#-----------------------------------------
load_env() {
  local optional="false"
  if [ "${1:-}" = "--optional" ]; then
    optional="true"
  fi

  if [ ! -f "${ENV_FILE}" ] && [ "${optional}" != "true" ]; then
    if [ -f "${ENV_EXAMPLE_FILE}" ]; then
      cp "${ENV_EXAMPLE_FILE}" "${ENV_FILE}"
      log_info "Created .env from .env.example"
    else
      die "Neither .env nor .env.example was found in ${ROOT_DIR}."
    fi
  fi

  if [ -f "${ENV_FILE}" ]; then
    set -a
    # shellcheck disable=SC1090
    . "${ENV_FILE}"
    set +a
  fi

  PROJECT="${PROJECT:-}"
  DOMAIN="${DOMAIN:-kanva.localhost}"
  HTTP_PORT="${HTTP_PORT:-80}"
  HTTPS_PORT="${HTTPS_PORT:-443}"
  POSTGRES_DB="${POSTGRES_DB:-db_kanva}"
  POSTGRES_USER="${POSTGRES_USER:-postgres}"
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
}

#-----------------------------------------
# Verify Docker CLI, reachable daemon, and Docker Compose V2 availability.
#
# @return void Exits with code 1 if any prerequisite check fails.
#-----------------------------------------
preflight_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    die "Docker is not installed or not in PATH."
  fi
  if ! docker info >/dev/null 2>&1; then
    die "Docker daemon is not running or current user lacks permission."
  fi
  if ! docker compose version >/dev/null 2>&1; then
    die "Docker Compose V2 ('docker compose') is required."
  fi
}

#-----------------------------------------
# Detect the normalized host platform identifier.
#
# @stdout One of 'macos', 'wsl', or 'linux'.
# @return void Exits with code 1 on unsupported host platforms.
#-----------------------------------------
detect_os() {
  local uname_s
  uname_s="$(uname -s)"
  case "${uname_s}" in
    Darwin)
      printf 'macos\n'
      ;;
    Linux)
      if [ -r /proc/version ] && grep -qi 'microsoft' /proc/version; then
        printf 'wsl\n'
      else
        printf 'linux\n'
      fi
      ;;
    *)
      die "Unsupported host OS: ${uname_s}. Supported: Linux, macOS, Windows WSL2."
      ;;
  esac
}

#-----------------------------------------
# Run docker compose scoped to the configured PROJECT, .env, and Compose file.
#
# @param  string $@ Arguments forwarded to docker compose.
# @global string PROJECT Compose project name.
# @global string ENV_FILE Path to .env.
# @global string COMPOSE_FILE Path to docker-compose.yml.
# @return int Exit code from docker compose.
#-----------------------------------------
dc() {
  docker compose --project-name "${PROJECT}" --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"
}

#-----------------------------------------
# Execute a command inside a Compose service container, disabling TTY if non-interactive.
#
# @param  string $@ Service name and command arguments passed to dc exec.
# @return int Exit code from docker compose exec.
#-----------------------------------------
dc_exec() {
  if [ -t 0 ]; then
    dc exec "$@"
  else
    dc exec -T "$@"
  fi
}

#-----------------------------------------
# Build the canonical HTTPS base URL for the configured DOMAIN and HTTPS_PORT.
#
# @global string DOMAIN Configured application domain.
# @global string HTTPS_PORT Configured host HTTPS port.
# @stdout Base URL (omitting :443 for the standard HTTPS port).
# @return void
#-----------------------------------------
app_url() {
  if [ "${HTTPS_PORT}" = "443" ]; then
    printf 'https://%s\n' "${DOMAIN}"
  else
    printf 'https://%s:%s\n' "${DOMAIN}" "${HTTPS_PORT}"
  fi
}

#-----------------------------------------
# Assert that the container for a given Compose service is currently running.
#
# @param  string $1 Compose service name (e.g., 'db', 'api', 'ui', 'caddy').
# @global string PROJECT Container name prefix.
# @return void Exits with code 1 if the container is not running.
#-----------------------------------------
require_running_container() {
  local service="$1"
  local cname="${PROJECT}-${service}"
  local running
  running="$(docker inspect -f '{{.State.Running}}' "${cname}" 2>/dev/null || printf 'false')"
  if [ "${running}" != "true" ]; then
    die "Container '${cname}' is not running. Start it with: ./dev.sh up ${service}"
  fi
}

# ------------------------------------------------------------------------------
# TLS Lifecycle, Expiry Detection & Host Trust Sync
# ------------------------------------------------------------------------------

#-----------------------------------------
# Compute the colon-free uppercase SHA-1 fingerprint of an X.509 certificate file.
#
# @param  string $1 Path to the PEM certificate file.
# @stdout SHA-1 fingerprint string, or empty if unavailable.
# @return int 0
#-----------------------------------------
cert_sha1_fingerprint() {
  local file="$1"
  if [ ! -s "${file}" ] || ! command -v openssl >/dev/null 2>&1; then
    return 0
  fi
  openssl x509 -noout -fingerprint -sha1 -in "${file}" 2>/dev/null | sed 's/.*=//;s/://g' || true
}

#-----------------------------------------
# Check whether a certificate file exists and remains valid beyond CERT_RENEW_WINDOW_SEC.
#
# @param  string $1 Path to the PEM certificate file.
# @global int CERT_RENEW_WINDOW_SEC Minimum remaining validity in seconds (86400s).
# @return int 0 if valid outside the renewal window, 1 if missing/expired/expiring.
#-----------------------------------------
cert_is_valid_window() {
  local file="$1"
  if [ ! -s "${file}" ]; then
    return 1
  fi
  if ! command -v openssl >/dev/null 2>&1; then
    return 0
  fi
  openssl x509 -noout -checkend "${CERT_RENEW_WINDOW_SEC}" -in "${file}" >/dev/null 2>&1
}

#-----------------------------------------
# Poll until Caddy generates its internal local Root CA certificate inside the container.
#
# @global string PROJECT Container name prefix.
# @global string DOMAIN Target domain for lazy-PKI trigger probe.
# @global string HTTPS_PORT Host HTTPS port.
# @return void Exits with code 1 on timeout.
#-----------------------------------------
wait_for_caddy_root_ca() {
  local caddy_container="${PROJECT}-caddy"
  local ca_path="/data/caddy/pki/authorities/local/root.crt"
  local attempts=20
  local i=1

  log_info "Waiting for Caddy Root CA inside ${caddy_container}..."
  while [ "${i}" -le "${attempts}" ]; do
    if docker exec "${caddy_container}" test -s "${ca_path}" 2>/dev/null; then
      return 0
    fi
    # Trigger a local TLS handshake on attempt 4 in case PKI initializes lazily
    if [ "${i}" -eq 4 ] && command -v curl >/dev/null 2>&1; then
      curl -ksS --max-time 2 --resolve "${DOMAIN}:${HTTPS_PORT}:127.0.0.1" "$(app_url)" >/dev/null 2>&1 || true
    fi
    sleep 1
    i=$((i + 1))
  done

  die "Timed out waiting for ${ca_path} inside ${caddy_container}. Check logs: ./dev.sh logs caddy"
}

#-----------------------------------------
# Delete Caddy's internal local Root CA and leaf certs, restart caddy, and await re-minting.
#
# @global string PROJECT Container name prefix.
# @return void
#-----------------------------------------
rotate_caddy_ca() {
  local caddy_container="${PROJECT}-caddy"
  log_info "Regenerating Caddy local Root CA and leaf certificates inside ${caddy_container}..."
  docker exec "${caddy_container}" sh -c 'rm -rf /data/caddy/pki/authorities/local/* /data/caddy/certificates/local/*'
  dc restart caddy >/dev/null
  wait_for_caddy_root_ca
}

#-----------------------------------------
# Delete Caddy's cached local leaf certificates, restart caddy, and trigger re-issuance.
#
# @global string PROJECT Container name prefix.
# @global string DOMAIN Target domain for TLS handshake trigger.
# @global string HTTPS_PORT Host HTTPS port.
# @return void
#-----------------------------------------
rotate_caddy_leaf_certs() {
  local caddy_container="${PROJECT}-caddy"
  log_info "Regenerating Caddy leaf certificate for ${DOMAIN}..."
  docker exec "${caddy_container}" sh -c 'rm -rf /data/caddy/certificates/local/*'
  dc restart caddy >/dev/null
  if command -v curl >/dev/null 2>&1; then
    curl -ksS --max-time 3 --resolve "${DOMAIN}:${HTTPS_PORT}:127.0.0.1" "$(app_url)" >/dev/null 2>&1 || true
  fi
}

#-----------------------------------------
# Check whether the live leaf certificate served on loopback is valid beyond the renewal window.
#
# @global string DOMAIN SNI server name.
# @global string HTTPS_PORT Host HTTPS port.
# @return int 0 if valid or unreachable, 1 if the served leaf cert is expired/expiring.
#-----------------------------------------
live_leaf_cert_valid() {
  if ! command -v openssl >/dev/null 2>&1; then
    return 0
  fi
  local tmp_leaf
  tmp_leaf="$(mktemp "${TMPDIR:-/tmp}/db-kanva-leaf.XXXXXX")"
  if printf '' | openssl s_client -servername "${DOMAIN}" -connect "127.0.0.1:${HTTPS_PORT}" 2>/dev/null \
    | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > "${tmp_leaf}" \
    && [ -s "${tmp_leaf}" ]; then
    if cert_is_valid_window "${tmp_leaf}"; then
      rm -f "${tmp_leaf}"
      return 0
    fi
    rm -f "${tmp_leaf}"
    return 1
  fi
  rm -f "${tmp_leaf}"
  # If Caddy isn't reachable yet on loopback, don't force leaf rotation solely on that
  return 0
}

#-----------------------------------------
# Compare the exported CERT_FILE against Caddy's active in-container Root CA.
#
# @global string PROJECT Container name prefix.
# @global string CERT_FILE Local exported Root CA path.
# @return int 0 if byte-identical, 1 if missing or drifted.
#-----------------------------------------
caddy_ca_matches_exported() {
  local caddy_container="${PROJECT}-caddy"
  local ca_path="/data/caddy/pki/authorities/local/root.crt"
  if [ ! -s "${CERT_FILE}" ]; then
    return 1
  fi
  local tmp_ca
  tmp_ca="$(mktemp "${TMPDIR:-/tmp}/db-kanva-ca.XXXXXX")"
  if ! docker cp "${caddy_container}:${ca_path}" "${tmp_ca}" >/dev/null 2>&1; then
    rm -f "${tmp_ca}"
    return 1
  fi
  if cmp -s "${CERT_FILE}" "${tmp_ca}"; then
    rm -f "${tmp_ca}"
    return 0
  fi
  rm -f "${tmp_ca}"
  return 1
}

#-----------------------------------------
# Check whether Linux system CA anchors and optional NSS DB match CERT_FILE.
#
# @global string PROJECT Prefix for installed CA filename and NSS nickname.
# @global string CERT_FILE Local exported Root CA path.
# @return int 0 if synced, 1 if update is required.
#-----------------------------------------
linux_host_trust_matches() {
  local cert_name="${PROJECT}-caddy-local-root.crt"
  local nssdb="${HOME}/.pki/nssdb"
  local nickname="${PROJECT}-caddy-root"

  if command -v update-ca-certificates >/dev/null 2>&1 && [ -d /usr/local/share/ca-certificates ]; then
    local target="/usr/local/share/ca-certificates/${cert_name}"
    [ -f "${target}" ] && cmp -s "${CERT_FILE}" "${target}" || return 1
  elif command -v update-ca-trust >/dev/null 2>&1 && [ -d /etc/pki/ca-trust/source/anchors ]; then
    local target="/etc/pki/ca-trust/source/anchors/${cert_name}"
    [ -f "${target}" ] && cmp -s "${CERT_FILE}" "${target}" || return 1
  else
    return 1
  fi

  if command -v certutil >/dev/null 2>&1 && [ -d "${nssdb}" ]; then
    certutil -d "sql:${nssdb}" -L -n "${nickname}" >/dev/null 2>&1 || return 1
  fi

  return 0
}

#-----------------------------------------
# Check whether macOS System Keychain contains the SHA-1 fingerprint of CERT_FILE.
#
# @global string CERT_FILE Local exported Root CA path.
# @return int 0 if present, 1 otherwise.
#-----------------------------------------
macos_host_trust_matches() {
  local fingerprint
  fingerprint="$(cert_sha1_fingerprint "${CERT_FILE}")"
  if [ -z "${fingerprint}" ]; then
    return 1
  fi
  security find-certificate -a -Z /Library/Keychains/System.keychain 2>/dev/null | grep -qi "${fingerprint}"
}

#-----------------------------------------
# Check whether both WSL2 Linux and Windows CurrentUser Root stores trust CERT_FILE.
#
# @global string CERT_FILE Local exported Root CA path.
# @return int 0 if both stores match, 1 otherwise.
#-----------------------------------------
wsl_host_trust_matches() {
  linux_host_trust_matches || return 1
  if command -v certutil.exe >/dev/null 2>&1; then
    local fingerprint
    fingerprint="$(cert_sha1_fingerprint "${CERT_FILE}")"
    if [ -n "${fingerprint}" ]; then
      certutil.exe -user -verifystore Root "${fingerprint}" >/dev/null 2>&1 || return 1
    fi
  fi
  return 0
}

#-----------------------------------------
# Verify whether the current host OS trust store is already synced with CERT_FILE.
#
# @global string CERT_FILE Local exported Root CA path.
# @return int 0 if synced, 1 if trust installation/update is needed.
#-----------------------------------------
host_trust_is_synced() {
  if [ ! -s "${CERT_FILE}" ]; then
    return 1
  fi
  local os
  os="$(detect_os)"
  case "${os}" in
    macos) macos_host_trust_matches ;;
    wsl)   wsl_host_trust_matches ;;
    linux) linux_host_trust_matches ;;
  esac
}

#-----------------------------------------
# Determine whether the local Root CA or live leaf cert needs export, rotation, or trust sync.
#
# @global string CERT_FILE Local exported Root CA path.
# @return int 0 when refresh is needed, 1 when everything is valid and synced.
#-----------------------------------------
cert_needs_refresh() {
  if ! cert_is_valid_window "${CERT_FILE}"; then
    return 0
  fi
  if ! caddy_ca_matches_exported; then
    return 0
  fi
  if ! host_trust_is_synced; then
    return 0
  fi
  if ! live_leaf_cert_valid; then
    return 0
  fi
  return 1
}

#-----------------------------------------
# Idempotently install CERT_FILE into the Linux distro system CA trust store (requires sudo).
#
# @global string PROJECT Prefix for installed CA filename.
# @global string CERT_FILE Local exported Root CA path.
# @return int 0
#-----------------------------------------
install_linux_system_cert() {
  local cert_name="${PROJECT}-caddy-local-root.crt"

  if command -v update-ca-certificates >/dev/null 2>&1 && [ -d /usr/local/share/ca-certificates ]; then
    local target="/usr/local/share/ca-certificates/${cert_name}"
    if [ -f "${target}" ] && cmp -s "${CERT_FILE}" "${target}"; then
      log_info "Linux system trust store already up to date (${target})."
    else
      log_info "Installing Root CA into ${target} (requires sudo)..."
      sudo cp "${CERT_FILE}" "${target}"
      sudo chmod 644 "${target}"
      sudo update-ca-certificates
    fi
    return 0
  fi

  if command -v update-ca-trust >/dev/null 2>&1 && [ -d /etc/pki/ca-trust/source/anchors ]; then
    local target="/etc/pki/ca-trust/source/anchors/${cert_name}"
    if [ -f "${target}" ] && cmp -s "${CERT_FILE}" "${target}"; then
      log_info "RHEL/Fedora trust store already up to date (${target})."
    else
      log_info "Installing Root CA into ${target} (requires sudo)..."
      sudo cp "${CERT_FILE}" "${target}"
      sudo chmod 644 "${target}"
      sudo update-ca-trust extract
    fi
    return 0
  fi

  if command -v trust >/dev/null 2>&1; then
    log_info "Installing Root CA via p11-kit trust anchor (requires sudo)..."
    sudo trust anchor --store "${CERT_FILE}"
    return 0
  fi

  log_warn "Could not detect Linux CA trust updater. Install ${CERT_FILE} manually."
}

#-----------------------------------------
# Prune old entries and register CERT_FILE in the user's Chrome/Chromium NSS database.
#
# @global string PROJECT Prefix for NSS certificate nickname.
# @global string CERT_FILE Local exported Root CA path.
# @return void
#-----------------------------------------
install_linux_nss_cert() {
  local nssdb="${HOME}/.pki/nssdb"
  local nickname="${PROJECT}-caddy-root"
  if command -v certutil >/dev/null 2>&1 && [ -d "${nssdb}" ]; then
    while certutil -d "sql:${nssdb}" -D -n "${nickname}" >/dev/null 2>&1; do
      :
    done
    certutil -d "sql:${nssdb}" -A -t "C,," -n "${nickname}" -i "${CERT_FILE}"
    log_info "Updated Chrome/Chromium NSS trust database (${nssdb})."
  fi
}

#-----------------------------------------
# Prune any rotated Root CA and trust CERT_FILE in macOS System Keychain (requires sudo).
#
# @param  string $1 Optional previous SHA-1 fingerprint to prune when rotated.
# @global string CERT_FILE Local exported Root CA path.
# @return int 0
#-----------------------------------------
install_macos_cert() {
  local old_fp="${1:-}"
  local new_fp
  new_fp="$(cert_sha1_fingerprint "${CERT_FILE}")"

  if [ -n "${old_fp}" ] && [ "${old_fp}" != "${new_fp}" ]; then
    if security find-certificate -a -Z /Library/Keychains/System.keychain 2>/dev/null | grep -qi "${old_fp}"; then
      log_info "Pruning stale Caddy Root CA from macOS System Keychain (requires sudo)..."
      sudo security delete-certificate -Z "${old_fp}" /Library/Keychains/System.keychain >/dev/null 2>&1 || true
    fi
  fi

  if [ -n "${new_fp}" ] && security find-certificate -a -Z /Library/Keychains/System.keychain 2>/dev/null | grep -qi "${new_fp}"; then
    log_info "macOS System Keychain already trusts this Caddy Root CA."
    return 0
  fi

  log_info "Adding Root CA to macOS System Keychain (requires sudo)..."
  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "${CERT_FILE}"
}

#-----------------------------------------
# Prune any rotated Root CA and install CERT_FILE into the Windows CurrentUser Root store via WSL2.
#
# @param  string $1 Optional previous SHA-1 fingerprint to prune when rotated.
# @global string CERT_FILE Local exported Root CA path.
# @return int 0
#-----------------------------------------
install_wsl_windows_cert() {
  local old_fp="${1:-}"
  if ! command -v wslpath >/dev/null 2>&1 || ! command -v certutil.exe >/dev/null 2>&1; then
    log_warn "wslpath or certutil.exe not found; import ${CERT_FILE} into Windows Root store manually."
    return 0
  fi

  local new_fp
  new_fp="$(cert_sha1_fingerprint "${CERT_FILE}")"

  if [ -n "${old_fp}" ] && [ "${old_fp}" != "${new_fp}" ]; then
    log_info "Pruning stale Caddy Root CA from Windows CurrentUser Root store..."
    certutil.exe -user -delstore Root "${old_fp}" >/dev/null 2>&1 || true
  fi

  local win_cert
  win_cert="$(wslpath -w "${CERT_FILE}")"
  log_info "Installing Root CA into Windows CurrentUser Root store..."
  certutil.exe -user -addstore Root "${win_cert}" >/dev/null
  log_info "Windows host Root store updated."
}

#-----------------------------------------
# Check whether DOMAIN resolves locally and print /etc/hosts guidance if unresolved.
#
# @global string DOMAIN Configured application domain.
# @return int 0
#-----------------------------------------
check_domain_resolution() {
  local resolved=""
  if command -v getent >/dev/null 2>&1; then
    resolved="$(getent hosts "${DOMAIN}" 2>/dev/null | awk '{print $1}' | head -n 1 || true)"
  elif command -v dscacheutil >/dev/null 2>&1; then
    resolved="$(dscacheutil -q host -a name "${DOMAIN}" 2>/dev/null | awk '/ip_address:/ {print $2; exit}' || true)"
  fi

  if [ "${resolved}" = "127.0.0.1" ] || [ "${resolved}" = "::1" ]; then
    log_info "Domain resolution OK: ${DOMAIN} -> ${resolved}"
    return 0
  fi

  case "${DOMAIN}" in
    *.localhost|localhost)
      if [ -n "${resolved}" ]; then
        log_info "Domain ${DOMAIN} resolved to ${resolved}."
      else
        log_warn "${DOMAIN} did not resolve via system resolver (many browsers still map *.localhost to 127.0.0.1)."
        log_warn "If curl or tools fail to resolve ${DOMAIN}, add '127.0.0.1 ${DOMAIN}' to /etc/hosts."
      fi
      ;;
    *)
      log_warn "Domain '${DOMAIN}' does not resolve to 127.0.0.1/::1 (got: '${resolved:-none}')."
      log_warn "Add the following line to /etc/hosts (and C:\\Windows\\System32\\drivers\\etc\\hosts on WSL2):"
      printf '  127.0.0.1 %s\n' "${DOMAIN}"
      ;;
  esac
}

#-----------------------------------------
# Verify trusted HTTPS connectivity to the application URL using curl without -k.
#
# @global string DOMAIN Configured application domain.
# @return int 0 on TLS success (or missing curl), non-zero curl exit code on failure.
#-----------------------------------------
verify_https_endpoint() {
  local url
  url="$(app_url)"
  if ! command -v curl >/dev/null 2>&1; then
    log_warn "curl not installed; skipping HTTPS verification of ${url}."
    return 0
  fi

  local status
  local rc=0
  status="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "${url}")" || rc=$?
  if [ "${rc}" -eq 0 ]; then
    log_info "Trusted HTTPS verified for ${url} (HTTP ${status})."
    if [ "${status}" = "502" ]; then
      log_info "Note: HTTP 502 is expected until 'api' and 'ui' services are running."
    fi
  else
    log_warn "HTTPS verification for ${url} failed (curl exit ${rc})."
    log_warn "Check certificate trust and domain resolution for '${DOMAIN}'."
    return "${rc}"
  fi
}

#-----------------------------------------
# Export Caddy's Root CA (rotating if expired or --force), sync host trust, and verify HTTPS.
#
# @param  string $@ Optional '--force' / '-f' flag to force CA and leaf cert rotation.
# @global string PROJECT Container name prefix.
# @global string DOMAIN Target HTTPS domain.
# @global string CERT_DIR Directory where Caddy Root CA is exported.
# @global string CERT_FILE Exported Caddy Root CA file path.
# @return void
#-----------------------------------------
cmd_trust_cert() {
  local force="false"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force|-f) force="true" ;;
      *) die "Unknown option for trust-cert: $1 (supported: --force, -f)" ;;
    esac
    shift
  done

  require_running_container "caddy"

  local old_fp=""
  if [ -s "${CERT_FILE}" ]; then
    old_fp="$(cert_sha1_fingerprint "${CERT_FILE}")"
  fi

  if [ "${force}" = "true" ]; then
    rotate_caddy_ca
  else
    wait_for_caddy_root_ca
  fi

  mkdir -p "${CERT_DIR}"
  docker cp "${PROJECT}-caddy:/data/caddy/pki/authorities/local/root.crt" "${CERT_FILE}"

  if [ "${force}" != "true" ] && ! cert_is_valid_window "${CERT_FILE}"; then
    log_warn "Caddy's local Root CA is expired or expiring within 24h; rotating..."
    rotate_caddy_ca
    docker cp "${PROJECT}-caddy:/data/caddy/pki/authorities/local/root.crt" "${CERT_FILE}"
  elif [ "${force}" != "true" ] && ! live_leaf_cert_valid; then
    log_warn "Caddy's leaf certificate for ${DOMAIN} is expired or expiring within 24h; rotating..."
    rotate_caddy_leaf_certs
  fi

  log_info "Exported Caddy Root CA to ${CERT_FILE}"

  local os
  os="$(detect_os)"
  case "${os}" in
    macos)
      install_macos_cert "${old_fp}"
      ;;
    wsl)
      install_linux_system_cert
      install_linux_nss_cert
      install_wsl_windows_cert "${old_fp}"
      ;;
    linux)
      install_linux_system_cert
      install_linux_nss_cert
      ;;
  esac

  check_domain_resolution
  verify_https_endpoint

  printf '\n'
  log_info "Notes:"
  log_info "  - Firefox: enable 'security.enterprise_roots.enabled = true' in about:config (or import ${CERT_FILE})."
  log_info "  - Host Node.js CLIs: export NODE_EXTRA_CA_CERTS=\"${CERT_FILE}\""
}

#-----------------------------------------
# Automatically sync local HTTPS certificates if caddy is running and refresh is needed.
#
# @global string PROJECT Container name prefix.
# @return int 0
#-----------------------------------------
ensure_trusted_cert() {
  local caddy_running
  caddy_running="$(docker inspect -f '{{.State.Running}}' "${PROJECT}-caddy" 2>/dev/null || printf 'false')"
  if [ "${caddy_running}" != "true" ]; then
    return 0
  fi

  wait_for_caddy_root_ca

  if cert_needs_refresh; then
    log_info "Local HTTPS certificate is missing, expiring, or not yet trusted; syncing..."
    cmd_trust_cert
  else
    log_info "Local HTTPS certificate is valid and trusted."
  fi
}

# ------------------------------------------------------------------------------
# Command Dispatch
# ------------------------------------------------------------------------------

#-----------------------------------------
# Start Compose services in detached mode and auto-sync Caddy HTTPS trust when applicable.
#
# @param  string $@ Optional service names; defaults to all services.
# @global string PROJECT Compose project name.
# @return void
#-----------------------------------------
cmd_up() {
  dc up -d "$@"

  local should_sync_cert="false"
  if [ "$#" -eq 0 ]; then
    should_sync_cert="true"
  else
    local svc
    for svc in "$@"; do
      if [ "${svc}" = "caddy" ]; then
        should_sync_cert="true"
        break
      fi
    done
  fi

  if [ "${should_sync_cert}" = "true" ]; then
    ensure_trusted_cert
  fi

  log_info "Stack '${PROJECT}' started. App URL: $(app_url)"
}

#-----------------------------------------
# Stop and remove Compose containers and networks.
#
# @param  string $@ Optional arguments forwarded to docker compose down.
# @return void
#-----------------------------------------
cmd_down() {
  dc down "$@"
}

#-----------------------------------------
# Restart all or selected Compose services.
#
# @param  string $@ Optional service names or flags.
# @return void
#-----------------------------------------
cmd_restart() {
  dc restart "$@"
}

#-----------------------------------------
# Build or rebuild Docker images for all or selected services.
#
# @param  string $@ Optional service names or build flags.
# @return void
#-----------------------------------------
cmd_build() {
  dc build "$@"
}

#-----------------------------------------
# Stream the last 100 log lines from all or selected Compose services.
#
# @param  string $@ Optional service names.
# @return void
#-----------------------------------------
cmd_logs() {
  dc logs -f --tail=100 "$@"
}

#-----------------------------------------
# Display Compose container status and health.
#
# @param  string $@ Optional arguments forwarded to docker compose ps.
# @return void
#-----------------------------------------
cmd_ps() {
  dc ps "$@"
}

#-----------------------------------------
# Open an interactive shell or execute a command inside a running service container.
#
# @param  string $1 Target Compose service name.
# @param  string $@ Optional command and arguments to run instead of an interactive shell.
# @return void
#-----------------------------------------
cmd_shell() {
  local service="${1:-}"
  if [ -z "${service}" ]; then
    die "Usage: ./dev.sh shell <service> [command...]"
  fi
  shift
  require_running_container "${service}"

  if [ "$#" -gt 0 ]; then
    dc_exec "${service}" "$@"
  else
    dc_exec "${service}" sh -c 'if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi'
  fi
}

#-----------------------------------------
# Run an AdonisJS Ace CLI command inside the running api container.
#
# @param  string $@ Ace subcommand and arguments.
# @return void
#-----------------------------------------
cmd_ace() {
  if [ "$#" -eq 0 ]; then
    die "Usage: ./dev.sh ace <ace-command...>"
  fi
  require_running_container "api"
  dc_exec api node ace "$@"
}

#-----------------------------------------
# Run PostgreSQL psql or AdonisJS Lucid migration/seeder helpers.
#
# @param  string $1 Optional subcommand: 'psql' (default), 'migrate', 'seed', or 'fresh'.
# @param  string $@ Extra flags forwarded to psql or node ace.
# @global string POSTGRES_USER PostgreSQL user for psql.
# @global string POSTGRES_DB PostgreSQL database name for psql.
# @return void
#-----------------------------------------
cmd_db() {
  local sub="${1:-psql}"
  if [ "$#" -gt 0 ]; then
    shift
  fi

  case "${sub}" in
    psql)
      require_running_container "db"
      dc_exec db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" "$@"
      ;;
    migrate)
      require_running_container "api"
      dc_exec api node ace migration:run "$@"
      ;;
    seed)
      require_running_container "api"
      dc_exec api node ace db:seed "$@"
      ;;
    fresh)
      require_running_container "api"
      dc_exec api node ace migration:fresh --seed "$@"
      ;;
    *)
      die "Unknown db subcommand '${sub}'. Use: ./dev.sh db [psql|migrate|seed|fresh]"
      ;;
  esac
}

#-----------------------------------------
# Run an Expo CLI command inside the running ui container.
#
# @param  string $@ Expo subcommand and arguments.
# @return void
#-----------------------------------------
cmd_expo() {
  if [ "$#" -eq 0 ]; then
    die "Usage: ./dev.sh expo <expo-args...>"
  fi
  require_running_container "ui"
  dc_exec ui npx expo "$@"
}

#-----------------------------------------
# Tear down containers, networks, and named volumes after confirmation.
#
# @param  string $1 Optional '--yes' / '-y' flag to skip the confirmation prompt.
# @global string PROJECT Compose project name.
# @return void
#-----------------------------------------
cmd_clean() {
  local auto_yes="false"
  if [ "${1:-}" = "--yes" ] || [ "${1:-}" = "-y" ]; then
    auto_yes="true"
  fi

  if [ "${auto_yes}" != "true" ]; then
    printf "This will stop '%s' containers and DELETE named volumes (%s-pgdata, %s-caddy-data, %s-caddy-config).\n" \
      "${PROJECT}" "${PROJECT}" "${PROJECT}" "${PROJECT}"
    printf 'Continue? [y/N] '
    local reply=""
    read -r reply
    case "${reply}" in
      y|Y|yes|YES) ;;
      *)
        log_info "Aborted."
        exit 0
        ;;
    esac
  fi

  dc down -v --remove-orphans
  log_info "Cleaned project '${PROJECT}'. Run './dev.sh trust-cert' after the next './dev.sh up' to re-sync Caddy's Root CA."
}

#-----------------------------------------
# Generate a commit message via Antigravity CLI using the git-commit skill
# and copy it to the host clipboard.
#
# @global string ROOT_DIR Repository root directory.
# @stdout Generated commit message output from agy.
# @return void
#-----------------------------------------
cmd_commit_msg() {
  if ! command -v agy >/dev/null 2>&1; then
    die "Antigravity CLI ('agy') is not installed or not in PATH."
  fi

  local msg
  local clean_msg
  msg="$(cd "${ROOT_DIR}" && agy -p "Use the git-commit skill to generate a commit message")"
  clean_msg="$(printf '%s\n' "${msg}" | sed -e '/^[[:space:]]*```[a-zA-Z0-9_-]*[[:space:]]*$/d')"
  printf '%s\n' "${clean_msg}"

  if command -v pbcopy >/dev/null 2>&1; then
    printf '%s\n' "${clean_msg}" | pbcopy
    log_info "Copied commit message to clipboard (pbcopy)."
  elif command -v clip.exe >/dev/null 2>&1; then
    printf '%s\n' "${clean_msg}" | clip.exe
    log_info "Copied commit message to clipboard (clip.exe)."
  elif [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy >/dev/null 2>&1; then
    printf '%s\n' "${clean_msg}" | wl-copy
    log_info "Copied commit message to clipboard (wl-copy)."
  elif command -v xclip >/dev/null 2>&1; then
    printf '%s\n' "${clean_msg}" | xclip -selection clipboard
    log_info "Copied commit message to clipboard (xclip)."
  elif command -v xsel >/dev/null 2>&1; then
    printf '%s\n' "${clean_msg}" | xsel --clipboard --input
    log_info "Copied commit message to clipboard (xsel)."
  elif command -v wl-copy >/dev/null 2>&1; then
    printf '%s\n' "${clean_msg}" | wl-copy
    log_info "Copied commit message to clipboard (wl-copy)."
  else
    log_warn "No clipboard utility found (pbcopy, clip.exe, wl-copy, xclip, xsel)."
  fi
}

#-----------------------------------------
# Print CLI usage, optional project metadata, and available subcommands.
#
# @global string PROJECT Compose project name.
# @stdout Formatted help text.
# @return void
#-----------------------------------------
cmd_help() {
  printf 'Usage: ./dev.sh <command> [args...]\n\n'
  if [ -n "${PROJECT:-}" ]; then
    printf 'Project: %s\n\n' "${PROJECT}"
  fi
  cat <<'EOF'
Commands:
  up [services...]        Start containers in background (auto-syncs Caddy HTTPS cert)
  down [args...]          Stop and remove containers/networks
  restart [services...]   Restart containers
  build [services...]     Build or rebuild service images
  logs [services...]      Tail container logs
  ps (status)             Show container status
  shell <service> [cmd]   Open shell (or run command) in a service container
  ace <args...>           Run AdonisJS Ace CLI inside api container
  db [psql|migrate|seed|fresh]
                          Run Postgres psql or AdonisJS DB commands (also db:*)
  expo <args...>          Run Expo CLI inside ui container
  trust-cert [--force]    Export Caddy Root CA (rotating if expired/--force), sync host trust, and verify HTTPS
  commit-msg (git-commit) Generate a commit message using the git-commit skill via agy
  clean [-y|--yes]        Stop stack and remove volumes
  help                    Show this help message
EOF
}

#-----------------------------------------
# Idempotently configure repo git hooks (.githooks) and check for git-flow-avh.
#
# @global string ROOT_DIR Repository root directory.
# @return void
#-----------------------------------------
setup_git_hooks() {
  if ! command -v git >/dev/null 2>&1; then
    return 0
  fi
  if ! git -C "${ROOT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi

  local current_hooks_path
  current_hooks_path="$(git -C "${ROOT_DIR}" config --get core.hooksPath 2>/dev/null || true)"
  if [ "${current_hooks_path}" != ".githooks" ]; then
    git -C "${ROOT_DIR}" config core.hooksPath .githooks
    log_info "Configured git core.hooksPath -> .githooks"
  fi

  local gitflow_version
  gitflow_version="$(git flow version 2>/dev/null || true)"
  case "${gitflow_version}" in
    *"AVH Edition"*) ;;
    *)
      log_warn "git-flow-avh (AVH Edition) not detected; install git-flow-avh for automatic master -> develop hook execution."
      ;;
  esac
}

#-----------------------------------------
# CLI entrypoint: dispatch standalone commands without requiring .env or Docker,
# then load .env, validate Docker prerequisites, and dispatch stack subcommands.
#
# @param  string $@ CLI subcommand and optional arguments.
# @return void
#-----------------------------------------
main() {
  setup_git_hooks

  local cmd="${1:-help}"
  if [ "$#" -gt 0 ]; then
    shift
  fi

  case "${cmd}" in
    help|-h|--help)
      load_env --optional
      cmd_help
      exit 0
      ;;
    commit-msg|git-commit)
      cmd_commit_msg "$@"
      exit 0
      ;;
    up|down|restart|build|logs|ps|status|shell|ace|db|db:psql|db:migrate|db:seed|db:fresh|expo|trust-cert|clean)
      ;;
    *)
      load_env --optional
      log_err "Unknown command: ${cmd}"
      cmd_help
      exit 1
      ;;
  esac

  load_env
  preflight_docker

  case "${cmd}" in
    up)         cmd_up "$@" ;;
    down)       cmd_down "$@" ;;
    restart)    cmd_restart "$@" ;;
    build)      cmd_build "$@" ;;
    logs)       cmd_logs "$@" ;;
    ps|status)  cmd_ps "$@" ;;
    shell)      cmd_shell "$@" ;;
    ace)        cmd_ace "$@" ;;
    db)         cmd_db "$@" ;;
    db:psql)    cmd_db psql "$@" ;;
    db:migrate) cmd_db migrate "$@" ;;
    db:seed)    cmd_db seed "$@" ;;
    db:fresh)   cmd_db fresh "$@" ;;
    expo)       cmd_expo "$@" ;;
    trust-cert) cmd_trust_cert "$@" ;;
    clean)      cmd_clean "$@" ;;
  esac
}

main "$@"
