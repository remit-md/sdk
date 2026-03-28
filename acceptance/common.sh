#!/usr/bin/env bash
# common.sh — shared helpers for the 9-SDK acceptance suite.

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ─── Logging ──────────────────────────────────────────────────────────────────
log_pass()  { echo -e "${GREEN}[PASS]${RESET} $*"; }
log_fail()  { echo -e "${RED}[FAIL]${RESET} $*"; }
log_skip()  { echo -e "${YELLOW}[SKIP]${RESET} $*"; }
log_info()  { echo -e "${CYAN}[INFO]${RESET} $*"; }
log_step()  { echo -e "${BOLD}  ▸${RESET} $*"; }
log_weather() {
    local city="$1" region="$2" temp_f="$3" temp_c="$4" condition="$5" humidity="$6" wind="$7"
    echo ""
    echo -e "${CYAN}┌─────────────────────────────────────────────┐${RESET}"
    echo -e "${CYAN}│${RESET}  ${BOLD}x402 Weather Report${RESET} (paid USDC)            ${CYAN}│${RESET}"
    echo -e "${CYAN}├─────────────────────────────────────────────┤${RESET}"
    printf  "${CYAN}│${RESET}  %-14s %-28s ${CYAN}│${RESET}\n" "City:" "$city"
    printf  "${CYAN}│${RESET}  %-14s %-28s ${CYAN}│${RESET}\n" "Region:" "$region"
    printf  "${CYAN}│${RESET}  %-14s %-28s ${CYAN}│${RESET}\n" "Temperature:" "${temp_f}°F / ${temp_c}°C"
    printf  "${CYAN}│${RESET}  %-14s %-28s ${CYAN}│${RESET}\n" "Condition:" "$condition"
    printf  "${CYAN}│${RESET}  %-14s %-28s ${CYAN}│${RESET}\n" "Humidity:" "${humidity}%"
    printf  "${CYAN}│${RESET}  %-14s %-28s ${CYAN}│${RESET}\n" "Wind:" "$wind"
    echo -e "${CYAN}└─────────────────────────────────────────────┘${RESET}"
    echo ""
}

# ─── Env defaults ─────────────────────────────────────────────────────────────
export API_URL="${ACCEPTANCE_API_URL:-https://testnet.remit.md}"
export API_BASE="${API_URL}/api/v1"
export RPC_URL="${ACCEPTANCE_RPC_URL:-https://sepolia.base.org}"
export CHAIN_ID=84532
export USDC_ADDRESS="0x2d846325766921935f37d5b4478196d3ef93707c"

# ─── Prereq helpers ───────────────────────────────────────────────────────────
require_cmd() {
    local cmd="$1" label="${2:-$1}"
    if ! command -v "$cmd" &>/dev/null; then
        log_fail "Required command not found: $label ($cmd)"
        return 1
    fi
    return 0
}

check_runtime() {
    local lang="$1"
    case "$lang" in
        python)     require_cmd python3 "Python 3.10+" ;;
        typescript) require_cmd node "Node.js 18+" && require_cmd pnpm "pnpm" ;;
        go)         require_cmd go "Go 1.21+" ;;
        rust)       require_cmd cargo "Rust/Cargo" ;;
        dotnet)     require_cmd dotnet ".NET 8+" ;;
        java)       require_cmd gradle "Gradle" ;;
        ruby)       require_cmd ruby "Ruby 3.1+" && require_cmd gem "RubyGems" ;;
        swift)      require_cmd swift "Swift 5.9+" ;;
        elixir)     require_cmd mix "Elixir/Mix" ;;
        *) log_fail "Unknown language: $lang"; return 1 ;;
    esac
}

# ─── SDK root (relative to acceptance/) ───────────────────────────────────────
SDK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACCEPTANCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ALL_LANGUAGES=(python typescript go rust dotnet java ruby swift elixir)
