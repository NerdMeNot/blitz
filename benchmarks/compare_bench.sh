#!/bin/bash
# Blitz vs Rayon Comparative Benchmark
#
# Builds and runs both Blitz (Zig) and Rayon (Rust) benchmarks,
# then displays a formatted comparison table.
#
# Usage: ./compare_bench.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Box drawing characters
TL='┌' TR='┐' BL='└' BR='┘'
H='─' V='│'
LT='├' RT='┤' TT='┬' BT='┴' X='┼'

# ============================================================================
# Build Phase
# ============================================================================

echo -e "${BOLD}══════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}                    BLITZ vs RAYON COMPARATIVE BENCHMARK${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${BLUE}Building Blitz benchmark...${NC}"
cd "$PROJECT_DIR"
zig build-exe -O ReleaseFast -lc -femit-bin=benchmarks/blitz_bench --dep blitz -Mroot=benchmarks/rayon_compare.zig -Mblitz=api.zig 2>&1 | head -20 || {
    echo -e "${RED}Failed to build Blitz benchmark${NC}"
    exit 1
}
echo -e "${GREEN}✓ Blitz build complete${NC}"

echo -e "${BLUE}Building Rayon benchmark...${NC}"
cd "$SCRIPT_DIR/rayon"
cargo build --release 2>&1 | grep -v "Compiling\|Downloading\|Downloaded" | head -10 || {
    echo -e "${RED}Failed to build Rayon benchmark${NC}"
    exit 1
}
echo -e "${GREEN}✓ Rayon build complete${NC}"
echo ""

# ============================================================================
# Run Benchmarks
# ============================================================================

echo -e "${BLUE}Running Blitz benchmark...${NC}"
cd "$SCRIPT_DIR"
BLITZ_JSON=$(./blitz_bench 2>&1)
echo -e "${GREEN}✓ Blitz benchmark complete${NC}"

echo -e "${BLUE}Running Rayon benchmark...${NC}"
RAYON_JSON=$(./rayon/target/release/rayon_compare 2>&1)
echo -e "${GREEN}✓ Rayon benchmark complete${NC}"
echo ""

# ============================================================================
# Parse JSON Results
# ============================================================================

# Function to extract value from JSON
get_blitz() {
    echo "$BLITZ_JSON" | grep "\"$1\"" | sed 's/.*: *//' | sed 's/,$//' | tr -d ' '
}

get_rayon() {
    echo "$RAYON_JSON" | grep "\"$1\"" | sed 's/.*: *//' | sed 's/,$//' | tr -d ' '
}

# ============================================================================
# Table Drawing Functions
# ============================================================================

# Calculate diff percentage and color
calc_diff() {
    local blitz="$1"
    local rayon="$2"

    if [[ -z "$blitz" || -z "$rayon" || "$rayon" == "0" ]]; then
        echo "N/A"
        return
    fi

    local ratio=$(echo "scale=4; $blitz / $rayon" | bc 2>/dev/null)
    if [[ -z "$ratio" ]]; then
        echo "N/A"
        return
    fi

    local is_faster=$(echo "$ratio < 1" | bc 2>/dev/null)
    if [[ "$is_faster" == "1" ]]; then
        local pct=$(echo "scale=1; (1 - $ratio) * 100" | bc 2>/dev/null)
        echo -e "${GREEN}+${pct}% faster${NC}"
    else
        local pct=$(echo "scale=1; ($ratio - 1) * 100" | bc 2>/dev/null)
        echo -e "${RED}-${pct}% slower${NC}"
    fi
}

# Print horizontal line
hline() {
    local left="$1"
    local mid="$2"
    local right="$3"
    local w1="$4"
    local w2="$5"
    local w3="$6"
    local w4="$7"

    printf "%s" "$left"
    printf '%*s' $((w1+2)) '' | tr ' ' "$H"
    printf "%s" "$mid"
    printf '%*s' $((w2+2)) '' | tr ' ' "$H"
    printf "%s" "$mid"
    printf '%*s' $((w3+2)) '' | tr ' ' "$H"
    printf "%s" "$mid"
    printf '%*s' $((w4+2)) '' | tr ' ' "$H"
    printf "%s\n" "$right"
}

# Print table row
print_row() {
    local c1="$1"
    local c2="$2"
    local c3="$3"
    local c4="$4"
    local w1="$5"
    local w2="$6"
    local w3="$7"
    local w4="$8"

    # Strip ANSI codes for width calculation
    local c4_clean=$(echo -e "$c4" | sed $'s/\033\\[[0-9;]*m//g')
    local c4_len=${#c4_clean}
    local c4_pad=$((w4 - c4_len))
    if [[ $c4_pad -lt 0 ]]; then c4_pad=0; fi

    printf "%s %-${w1}s %s %${w2}s %s %${w3}s %s %-s%*s %s\n" \
        "$V" "$c1" "$V" "$c2" "$V" "$c3" "$V" "$c4" "$c4_pad" "" "$V"
}

# Section header
section_header() {
    echo ""
    echo -e "${BOLD}$1${NC}"
}

# ============================================================================
# Display Results
# ============================================================================

echo -e "${BOLD}══════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}                              COMPARISON RESULTS${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════════════════════${NC}"

# Column widths
W1=24  # Benchmark name
W2=12  # Blitz
W3=12  # Rayon
W4=18  # Difference

# ─────────────────────────────────────────────────────────────────────────────
# 1. Fork-Join Overhead
# ─────────────────────────────────────────────────────────────────────────────
section_header "1. FORK-JOIN OVERHEAD (ns/fork, lower is better)"

hline "$TL" "$TT" "$TR" $W1 $W2 $W3 $W4
print_row "Benchmark" "Blitz" "Rayon" "Difference" $W1 $W2 $W3 $W4
hline "$LT" "$X" "$RT" $W1 $W2 $W3 $W4

for depth in 10 15 20; do
    key="fork_join_depth_$depth"
    b=$(get_blitz "$key")
    r=$(get_rayon "$key")
    diff=$(calc_diff "$b" "$r")
    print_row "Depth $depth" "${b:-N/A}" "${r:-N/A}" "$diff" $W1 $W2 $W3 $W4
done

hline "$BL" "$BT" "$BR" $W1 $W2 $W3 $W4

# ─────────────────────────────────────────────────────────────────────────────
# 2. Parallel Fibonacci
# ─────────────────────────────────────────────────────────────────────────────
section_header "2. PARALLEL FIBONACCI (ms, lower is better)"

hline "$TL" "$TT" "$TR" $W1 $W2 $W3 $W4
print_row "Benchmark" "Blitz" "Rayon" "Difference" $W1 $W2 $W3 $W4
hline "$LT" "$X" "$RT" $W1 $W2 $W3 $W4

for n in 35 40; do
    key="fib_${n}_par_ms"
    b=$(get_blitz "$key")
    r=$(get_rayon "$key")
    diff=$(calc_diff "$b" "$r")
    print_row "fib($n) parallel" "${b:-N/A}" "${r:-N/A}" "$diff" $W1 $W2 $W3 $W4
done

for n in 35 40; do
    key="fib_${n}_seq_ms"
    b=$(get_blitz "$key")
    r=$(get_rayon "$key")
    diff=$(calc_diff "$b" "$r")
    print_row "fib($n) sequential" "${b:-N/A}" "${r:-N/A}" "$diff" $W1 $W2 $W3 $W4
done

hline "$BL" "$BT" "$BR" $W1 $W2 $W3 $W4

# ─────────────────────────────────────────────────────────────────────────────
# 3. Parallel Sum
# ─────────────────────────────────────────────────────────────────────────────
section_header "3. PARALLEL SUM - 10M elements (ms, lower is better)"

hline "$TL" "$TT" "$TR" $W1 $W2 $W3 $W4
print_row "Benchmark" "Blitz" "Rayon" "Difference" $W1 $W2 $W3 $W4
hline "$LT" "$X" "$RT" $W1 $W2 $W3 $W4

key="sum_10m_par_ms"
b=$(get_blitz "$key")
r=$(get_rayon "$key")
diff=$(calc_diff "$b" "$r")
print_row "Parallel sum" "${b:-N/A}" "${r:-N/A}" "$diff" $W1 $W2 $W3 $W4

key="sum_10m_seq_ms"
b=$(get_blitz "$key")
r=$(get_rayon "$key")
diff=$(calc_diff "$b" "$r")
print_row "Sequential sum" "${b:-N/A}" "${r:-N/A}" "$diff" $W1 $W2 $W3 $W4

hline "$BL" "$BT" "$BR" $W1 $W2 $W3 $W4

# ─────────────────────────────────────────────────────────────────────────────
# 4. PDQSort
# ─────────────────────────────────────────────────────────────────────────────
section_header "4. PARALLEL PDQSORT - 1M elements (ms, lower is better)"

hline "$TL" "$TT" "$TR" $W1 $W2 $W3 $W4
print_row "Pattern" "Blitz" "Rayon" "Difference" $W1 $W2 $W3 $W4
hline "$LT" "$X" "$RT" $W1 $W2 $W3 $W4

for pattern in random sorted reverse equal; do
    key="sort_1m_${pattern}_ms"
    b=$(get_blitz "$key")
    r=$(get_rayon "$key")
    diff=$(calc_diff "$b" "$r")
    # Capitalize first letter
    label="$(tr '[:lower:]' '[:upper:]' <<< ${pattern:0:1})${pattern:1}"
    print_row "$label" "${b:-N/A}" "${r:-N/A}" "$diff" $W1 $W2 $W3 $W4
done

hline "$BL" "$BT" "$BR" $W1 $W2 $W3 $W4

# ─────────────────────────────────────────────────────────────────────────────
# 5. Find Operations
# ─────────────────────────────────────────────────────────────────────────────
section_header "5. FIND OPERATIONS - 10M elements (µs, lower is better)"

hline "$TL" "$TT" "$TR" $W1 $W2 $W3 $W4
print_row "Operation" "Blitz" "Rayon" "Difference" $W1 $W2 $W3 $W4
hline "$LT" "$X" "$RT" $W1 $W2 $W3 $W4

key="find_10m_early_us"
b=$(get_blitz "$key")
r=$(get_rayon "$key")
diff=$(calc_diff "$b" "$r")
print_row "find (early exit)" "${b:-N/A}" "${r:-N/A}" "$diff" $W1 $W2 $W3 $W4

key="position_10m_early_us"
b=$(get_blitz "$key")
r=$(get_rayon "$key")
diff=$(calc_diff "$b" "$r")
print_row "position (early)" "${b:-N/A}" "${r:-N/A}" "$diff" $W1 $W2 $W3 $W4

key="position_10m_mid_us"
b=$(get_blitz "$key")
r=$(get_rayon "$key")
diff=$(calc_diff "$b" "$r")
print_row "position (middle)" "${b:-N/A}" "${r:-N/A}" "$diff" $W1 $W2 $W3 $W4

hline "$BL" "$BT" "$BR" $W1 $W2 $W3 $W4

# ─────────────────────────────────────────────────────────────────────────────
# 6. Any/All Predicates
# ─────────────────────────────────────────────────────────────────────────────
section_header "6. ANY/ALL PREDICATES - 10M elements (µs, lower is better)"

hline "$TL" "$TT" "$TR" $W1 $W2 $W3 $W4
print_row "Operation" "Blitz" "Rayon" "Difference" $W1 $W2 $W3 $W4
hline "$LT" "$X" "$RT" $W1 $W2 $W3 $W4

key="any_10m_early_us"
b=$(get_blitz "$key")
r=$(get_rayon "$key")
diff=$(calc_diff "$b" "$r")
print_row "any (early exit)" "${b:-N/A}" "${r:-N/A}" "$diff" $W1 $W2 $W3 $W4

key="any_10m_full_us"
b=$(get_blitz "$key")
r=$(get_rayon "$key")
diff=$(calc_diff "$b" "$r")
print_row "any (full scan)" "${b:-N/A}" "${r:-N/A}" "$diff" $W1 $W2 $W3 $W4

key="all_10m_pass_us"
b=$(get_blitz "$key")
r=$(get_rayon "$key")
diff=$(calc_diff "$b" "$r")
print_row "all (pass)" "${b:-N/A}" "${r:-N/A}" "$diff" $W1 $W2 $W3 $W4

hline "$BL" "$BT" "$BR" $W1 $W2 $W3 $W4

# ─────────────────────────────────────────────────────────────────────────────
# 7. Min/Max by Key
# ─────────────────────────────────────────────────────────────────────────────
section_header "7. MIN/MAX BY KEY - 10M elements (µs, lower is better)"

hline "$TL" "$TT" "$TR" $W1 $W2 $W3 $W4
print_row "Operation" "Blitz" "Rayon" "Difference" $W1 $W2 $W3 $W4
hline "$LT" "$X" "$RT" $W1 $W2 $W3 $W4

key="min_by_key_10m_us"
b=$(get_blitz "$key")
r=$(get_rayon "$key")
diff=$(calc_diff "$b" "$r")
print_row "minByKey" "${b:-N/A}" "${r:-N/A}" "$diff" $W1 $W2 $W3 $W4

key="max_by_key_10m_us"
b=$(get_blitz "$key")
r=$(get_rayon "$key")
diff=$(calc_diff "$b" "$r")
print_row "maxByKey" "${b:-N/A}" "${r:-N/A}" "$diff" $W1 $W2 $W3 $W4

hline "$BL" "$BT" "$BR" $W1 $W2 $W3 $W4

# ─────────────────────────────────────────────────────────────────────────────
# 8. Iterator Combinators
# ─────────────────────────────────────────────────────────────────────────────
section_header "8. ITERATOR COMBINATORS (ms, lower is better)"

hline "$TL" "$TT" "$TR" $W1 $W2 $W3 $W4
print_row "Operation" "Blitz" "Rayon" "Difference" $W1 $W2 $W3 $W4
hline "$LT" "$X" "$RT" $W1 $W2 $W3 $W4

key="chunks_10m_1000_ms"
b=$(get_blitz "$key")
r=$(get_rayon "$key")
diff=$(calc_diff "$b" "$r")
print_row "chunks(1000) + sum" "${b:-N/A}" "${r:-N/A}" "$diff" $W1 $W2 $W3 $W4

key="enumerate_10m_ms"
b=$(get_blitz "$key")
r=$(get_rayon "$key")
diff=$(calc_diff "$b" "$r")
print_row "enumerate + forEach" "${b:-N/A}" "${r:-N/A}" "$diff" $W1 $W2 $W3 $W4

key="chain_2x5m_ms"
b=$(get_blitz "$key")
r=$(get_rayon "$key")
diff=$(calc_diff "$b" "$r")
print_row "chain(2×5M) + sum" "${b:-N/A}" "${r:-N/A}" "$diff" $W1 $W2 $W3 $W4

key="zip_10m_ms"
b=$(get_blitz "$key")
r=$(get_rayon "$key")
diff=$(calc_diff "$b" "$r")
print_row "zip + dot product" "${b:-N/A}" "${r:-N/A}" "$diff" $W1 $W2 $W3 $W4

key="flatten_1000x10k_ms"
b=$(get_blitz "$key")
r=$(get_rayon "$key")
diff=$(calc_diff "$b" "$r")
print_row "flatten(1000×10k) + sum" "${b:-N/A}" "${r:-N/A}" "$diff" $W1 $W2 $W3 $W4

hline "$BL" "$BT" "$BR" $W1 $W2 $W3 $W4

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}                                   LEGEND${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${GREEN}+X% faster${NC}  = Blitz is X% faster than Rayon (lower time)"
echo -e "  ${RED}-X% slower${NC}  = Blitz is X% slower than Rayon (higher time)"
echo ""
echo "  Note: Results may vary based on system load and hardware."
echo "  Both frameworks configured with 10 worker threads."
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Compute overall statistics
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}══════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}                                  SUMMARY${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

# Count wins
blitz_wins=0
rayon_wins=0
ties=0

ALL_KEYS="fork_join_depth_10 fork_join_depth_15 fork_join_depth_20 fib_35_par_ms fib_35_seq_ms fib_40_par_ms fib_40_seq_ms sum_10m_par_ms sum_10m_seq_ms sort_1m_random_ms sort_1m_sorted_ms sort_1m_reverse_ms sort_1m_equal_ms find_10m_early_us any_10m_early_us any_10m_full_us all_10m_pass_us chunks_10m_1000_ms min_by_key_10m_us max_by_key_10m_us position_10m_early_us position_10m_mid_us enumerate_10m_ms chain_2x5m_ms zip_10m_ms flatten_1000x10k_ms"

for key in $ALL_KEYS; do
    b=$(get_blitz "$key")
    r=$(get_rayon "$key")
    if [[ -n "$b" && -n "$r" && "$b" != "0" && "$r" != "0" ]]; then
        cmp=$(echo "$b < $r" | bc 2>/dev/null)
        if [[ "$cmp" == "1" ]]; then
            blitz_wins=$((blitz_wins + 1))
        elif [[ $(echo "$b > $r" | bc 2>/dev/null) == "1" ]]; then
            rayon_wins=$((rayon_wins + 1))
        else
            ties=$((ties + 1))
        fi
    fi
done

total=$((blitz_wins + rayon_wins + ties))
echo "  Benchmarks compared: $total"
echo -e "  Blitz wins:          ${GREEN}$blitz_wins${NC}"
echo -e "  Rayon wins:          ${RED}$rayon_wins${NC}"
echo "  Ties:                $ties"
echo ""
