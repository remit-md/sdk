#!/usr/bin/env bash
# run-all.sh — Orchestrator: install SDKs from source, run 9 flows in each of 9 languages.
#
# Usage:
#   ./run-all.sh                    # run all 9 languages
#   ./run-all.sh python typescript  # run specific languages
#   SDK_LANGUAGES=python,go ./run-all.sh  # via env var

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# ─── Parse languages ──────────────────────────────────────────────────────────
if [[ $# -gt 0 ]]; then
    LANGUAGES=("$@")
elif [[ -n "${SDK_LANGUAGES:-}" ]]; then
    IFS=',' read -ra LANGUAGES <<< "$SDK_LANGUAGES"
else
    LANGUAGES=("${ALL_LANGUAGES[@]}")
fi

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Remit SDK Acceptance Suite — 9 Flows × ${#LANGUAGES[@]} SDKs${RESET}"
echo -e "${BOLD}════════════════════════════════════════════════════${RESET}"
echo -e "  API:   ${API_URL}"
echo -e "  RPC:   ${RPC_URL}"
echo -e "  Chain: ${CHAIN_ID}"
echo ""

# ─── Check common prerequisites ──────────────────────────────────────────────
require_cmd curl "curl" || exit 1
require_cmd jq "jq" || exit 1

# ─── Results tracking ─────────────────────────────────────────────────────────
declare -A RESULTS
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

# ─── Per-language runner ──────────────────────────────────────────────────────
run_language() {
    local lang="$1"
    local lang_dir="$ACCEPTANCE_DIR/$lang"
    local log_file="$ACCEPTANCE_DIR/.logs/${lang}.log"

    echo ""
    echo -e "${BOLD}──── ${lang^^} ────────────────────────────────────────${RESET}"

    # Check runtime
    if ! check_runtime "$lang"; then
        log_skip "$lang: runtime not available"
        RESULTS[$lang]="SKIP"
        TOTAL_SKIP=$((TOTAL_SKIP + 1))
        return 0
    fi

    mkdir -p "$ACCEPTANCE_DIR/.logs"

    # Install SDK from source + run test script
    local exit_code=0
    case "$lang" in
        python)
            log_info "Installing Python SDK from source..."
            (cd "$SDK_ROOT/python" && pip install -e ".[dev]" -q 2>&1 | tail -1) || true
            pip install httpx -q 2>/dev/null || true
            log_info "Running 9 flows..."
            python3 "$lang_dir/test_flows.py" 2>&1 | tee "$log_file" || exit_code=$?
            ;;
        typescript)
            log_info "Installing TypeScript SDK from source..."
            (cd "$lang_dir" && pnpm install --frozen-lockfile 2>&1 | tail -1) || \
            (cd "$lang_dir" && pnpm install 2>&1 | tail -1) || true
            log_info "Running 9 flows..."
            (cd "$lang_dir" && npx tsx test_flows.ts) 2>&1 | tee "$log_file" || exit_code=$?
            ;;
        go)
            log_info "Building Go test binary..."
            (cd "$lang_dir" && go build -o /dev/null . 2>&1 | tail -5) || true
            log_info "Running 9 flows..."
            (cd "$lang_dir" && go run .) 2>&1 | tee "$log_file" || exit_code=$?
            ;;
        rust)
            log_info "Building Rust test binary..."
            (cd "$lang_dir" && cargo build --release 2>&1 | tail -3) || true
            log_info "Running 9 flows..."
            (cd "$lang_dir" && cargo run --release) 2>&1 | tee "$log_file" || exit_code=$?
            ;;
        dotnet)
            log_info "Building .NET project..."
            (cd "$lang_dir" && dotnet build -c Release -v q 2>&1 | tail -3) || true
            log_info "Running 9 flows..."
            (cd "$lang_dir" && dotnet run -c Release) 2>&1 | tee "$log_file" || exit_code=$?
            ;;
        java)
            log_info "Building Java project..."
            (cd "$lang_dir" && gradle build -x test --no-daemon -q 2>&1 | tail -3) || true
            log_info "Running 9 flows..."
            (cd "$lang_dir" && gradle run --no-daemon -q) 2>&1 | tee "$log_file" || exit_code=$?
            ;;
        ruby)
            log_info "Installing Ruby SDK from source..."
            (cd "$SDK_ROOT/ruby" && gem build remitmd.gemspec -q 2>/dev/null && gem install ./remitmd-*.gem --no-document -q 2>/dev/null) || true
            log_info "Running 9 flows..."
            ruby "$lang_dir/test_flows.rb" 2>&1 | tee "$log_file" || exit_code=$?
            ;;
        swift)
            log_info "Building Swift project..."
            (cd "$lang_dir" && swift build 2>&1 | tail -5) || true
            log_info "Running 9 flows..."
            (cd "$lang_dir" && swift run AcceptanceFlows) 2>&1 | tee "$log_file" || exit_code=$?
            ;;
        elixir)
            log_info "Building Elixir project..."
            (cd "$lang_dir" && mix deps.get --quiet 2>&1 | tail -3 && mix compile --no-warnings-as-errors 2>&1 | tail -3) || true
            log_info "Running 9 flows..."
            (cd "$lang_dir" && mix run test_flows.exs) 2>&1 | tee "$log_file" || exit_code=$?
            ;;
    esac

    # Parse result from last JSON line
    if [[ $exit_code -eq 0 ]]; then
        local passed failed
        passed=$(tail -1 "$log_file" | jq -r '.passed // 0' 2>/dev/null || echo "9")
        failed=$(tail -1 "$log_file" | jq -r '.failed // 0' 2>/dev/null || echo "0")
        RESULTS[$lang]="PASS ($passed/9)"
        TOTAL_PASS=$((TOTAL_PASS + passed))
        TOTAL_FAIL=$((TOTAL_FAIL + failed))
    else
        RESULTS[$lang]="FAIL (exit $exit_code)"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
}

# ─── Run all requested languages ─────────────────────────────────────────────
for lang in "${LANGUAGES[@]}"; do
    run_language "$lang"
done

# ─── Summary table ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Summary${RESET}"
echo -e "${BOLD}════════════════════════════════════════════════════${RESET}"
printf "  %-14s %s\n" "Language" "Result"
printf "  %-14s %s\n" "──────────" "──────────"
for lang in "${LANGUAGES[@]}"; do
    result="${RESULTS[$lang]:-UNKNOWN}"
    if [[ "$result" == SKIP* ]]; then
        printf "  %-14s ${YELLOW}%s${RESET}\n" "$lang" "$result"
    elif [[ "$result" == PASS* ]]; then
        printf "  %-14s ${GREEN}%s${RESET}\n" "$lang" "$result"
    else
        printf "  %-14s ${RED}%s${RESET}\n" "$lang" "$result"
    fi
done
echo ""
echo -e "  Total: ${GREEN}${TOTAL_PASS} passed${RESET}, ${RED}${TOTAL_FAIL} failed${RESET}, ${YELLOW}${TOTAL_SKIP} skipped${RESET}"
echo ""

# ─── Exit code ────────────────────────────────────────────────────────────────
if [[ $TOTAL_FAIL -gt 0 ]]; then
    exit 1
fi
