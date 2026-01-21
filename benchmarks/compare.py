#!/usr/bin/env python3
"""
Blitz vs Rayon Comparative Benchmark Runner

Runs both Blitz (Zig) and Rayon (Rust) benchmarks and outputs
a well-formatted comparison table.

Usage: python3 compare.py
"""

import subprocess
import re
import os
import sys
from dataclasses import dataclass
from typing import Optional

# ANSI colors for terminal output
class Colors:
    HEADER = '\033[95m'
    BLUE = '\033[94m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'

@dataclass
class BenchResult:
    """Single benchmark result"""
    name: str
    value_ms: float
    unit: str = "ms"
    extra: str = ""

def run_command(cmd: list[str], cwd: str) -> tuple[int, str, str]:
    """Run a command and return (returncode, stdout, stderr)"""
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=os.environ.copy())
    # Some programs output to stderr instead of stdout
    output = result.stdout if result.stdout else result.stderr
    return result.returncode, output, result.stderr

def build_blitz(script_dir: str) -> bool:
    """Build the Blitz benchmark"""
    blitz_dir = os.path.dirname(script_dir)
    print(f"{Colors.BLUE}Building Blitz benchmark...{Colors.ENDC}")

    cmd = [
        "zig", "build-exe",
        "-O", "ReleaseFast",
        "-lc",
        f"-femit-bin={os.path.join(script_dir, 'blitz_bench')}",
        "--dep", "blitz",
        "-Mroot=benchmarks/rayon_compare.zig",
        "-Mblitz=api.zig"
    ]

    code, stdout, stderr = run_command(cmd, blitz_dir)
    if code != 0:
        print(f"{Colors.RED}Failed to build Blitz:{Colors.ENDC}")
        print(stderr)
        return False
    print(f"{Colors.GREEN}Blitz build complete{Colors.ENDC}")
    return True

def build_rayon(script_dir: str) -> bool:
    """Build the Rayon benchmark"""
    rayon_dir = os.path.join(script_dir, "rayon")
    print(f"{Colors.BLUE}Building Rayon benchmark...{Colors.ENDC}")

    code, stdout, stderr = run_command(["cargo", "build", "--release"], rayon_dir)
    if code != 0:
        print(f"{Colors.RED}Failed to build Rayon:{Colors.ENDC}")
        print(stderr)
        return False
    print(f"{Colors.GREEN}Rayon build complete{Colors.ENDC}")
    return True

def run_blitz(script_dir: str) -> str:
    """Run Blitz benchmark and return output"""
    print(f"{Colors.BLUE}Running Blitz benchmark...{Colors.ENDC}")
    # Zig uses std.debug.print which goes to stderr
    result = subprocess.run(
        [os.path.join(script_dir, "blitz_bench")],
        cwd=script_dir,
        capture_output=True,
        text=True,
        env=os.environ.copy()
    )
    output = result.stderr if result.stderr else result.stdout
    if result.returncode != 0:
        print(f"{Colors.RED}Blitz benchmark failed (code={result.returncode}):{Colors.ENDC}")
        print(output[:500] if output else 'no output')
        return ""
    if not output:
        print(f"{Colors.RED}Blitz benchmark produced no output{Colors.ENDC}")
        return ""
    return output

def run_rayon(script_dir: str) -> str:
    """Run Rayon benchmark and return output"""
    print(f"{Colors.BLUE}Running Rayon benchmark...{Colors.ENDC}")
    rayon_bin = os.path.join(script_dir, "rayon", "target", "release", "rayon_compare")
    result = subprocess.run(
        [rayon_bin],
        cwd=script_dir,
        capture_output=True,
        text=True,
        env=os.environ.copy()
    )
    # Rust println! goes to stdout
    output = result.stdout if result.stdout else result.stderr
    if result.returncode != 0:
        print(f"{Colors.RED}Rayon benchmark failed (code={result.returncode}):{Colors.ENDC}")
        print(output[:500] if output else 'no output')
        return ""
    if not output:
        print(f"{Colors.RED}Rayon benchmark produced no output{Colors.ENDC}")
        return ""
    return output

def parse_fork_join(output: str) -> dict[int, float]:
    """Parse fork-join results: depth -> ns/fork"""
    results = {}
    pattern = r"Depth\s+(\d+):\s+[\d,]+\s+forks in\s+([\d.]+)\s+us\s+\(([\d.]+)\s+ns/fork\)"
    for match in re.finditer(pattern, output):
        depth = int(match.group(1))
        ns_per_fork = float(match.group(3))
        results[depth] = ns_per_fork
    return results

def parse_fib(output: str) -> dict[int, tuple[float, float]]:
    """Parse fibonacci results: n -> (parallel_ms, speedup)"""
    results = {}
    pattern = r"fib\((\d+)\):\s+parallel=([\d.]+)\s+ms,\s+sequential=([\d.]+)\s+ms,\s+speedup=([\d.]+)x"
    for match in re.finditer(pattern, output):
        n = int(match.group(1))
        par_ms = float(match.group(2))
        speedup = float(match.group(4))
        results[n] = (par_ms, speedup)
    return results

def parse_sum(output: str) -> dict[str, tuple[float, float]]:
    """Parse sum results: size -> (parallel_ms, speedup)"""
    results = {}
    pattern = r"sum\((\s*\d+M)\):\s+parallel=([\d.]+)\s+ms,\s+sequential=([\d.]+)\s+ms,\s+speedup=([\d.]+)x"
    for match in re.finditer(pattern, output):
        size = match.group(1).strip()
        par_ms = float(match.group(2))
        speedup = float(match.group(4))
        results[size] = (par_ms, speedup)
    return results

def parse_quicksort(output: str) -> dict[str, tuple[float, float]]:
    """Parse quicksort results: size -> (parallel_ms, speedup)"""
    results = {}
    # Match both "sort(..." and "par_sort(..."
    pattern = r"(?:par_)?sort\((\s*\d+M)\):\s+(?:parallel=)?([\d.]+)\s+ms"
    for match in re.finditer(pattern, output):
        size = match.group(1).strip()
        par_ms = float(match.group(2))
        # For PDQSort comparison, we get ms directly
        results[size] = (par_ms, 0.0)
    return results

def parse_pdqsort_patterns(output: str) -> dict[str, float]:
    """Parse PDQSort pattern results"""
    results = {}
    patterns = ["Random", "Sorted", "Reverse", "All equal"]
    for pattern in patterns:
        match = re.search(rf"{pattern}:\s+([\d.]+)\s+ms", output)
        if match:
            results[pattern] = float(match.group(1))
    return results

def parse_find(output: str) -> dict[str, float]:
    """Parse find results: key -> us"""
    results = {}
    # find(size, position): par=X us
    pattern = r"find\((\d+M),\s+(\w+)\):\s+par=([\d.]+)\s+us"
    for match in re.finditer(pattern, output):
        size = match.group(1)
        position = match.group(2)
        us = float(match.group(3))
        results[f"find({size},{position})"] = us

    # findFirst
    pattern = r"findFirst\((\d+M)\):\s+par=([\d.]+)\s+us"
    for match in re.finditer(pattern, output):
        size = match.group(1)
        us = float(match.group(2))
        results[f"findFirst({size})"] = us

    return results

def parse_any_all(output: str) -> dict[str, float]:
    """Parse any/all results"""
    results = {}
    pattern = r"(any|all)\(10M,\s+([^)]+)\):\s+([\d.]+)\s+us"
    for match in re.finditer(pattern, output):
        op = match.group(1)
        condition = match.group(2)
        us = float(match.group(3))
        results[f"{op}({condition})"] = us
    return results

def parse_minbykey(output: str) -> dict[str, tuple[float, float]]:
    """Parse minByKey results: size -> (par_ms, speedup)"""
    results = {}
    pattern = r"minByKey\((\d+M)\):\s+par=([\d.]+)\s+ms,\s+seq=([\d.]+)\s+ms,\s+speedup=([\d.]+)x"
    for match in re.finditer(pattern, output):
        size = match.group(1)
        par_ms = float(match.group(2))
        speedup = float(match.group(4))
        results[size] = (par_ms, speedup)
    return results

def parse_sortbykey(output: str) -> dict[str, float]:
    """Parse sortByKey results"""
    results = {}
    pattern = r"sort(?:By(?:Cached)?Key)\((\d+[KM])\):\s+([\d.]+)\s+ms"
    for match in re.finditer(pattern, output):
        size = match.group(1)
        ms = float(match.group(2))
        key = f"sortByKey({size})" if "Cached" not in match.group(0) else f"sortByCachedKey({size})"
        results[key] = ms
    return results

def parse_chunks(output: str) -> dict[int, float]:
    """Parse chunks results: chunk_size -> ms"""
    results = {}
    pattern = r"chunks\(10M,\s+(\d+)\):\s+([\d.]+)\s+ms"
    for match in re.finditer(pattern, output):
        chunk_size = int(match.group(1))
        ms = float(match.group(2))
        results[chunk_size] = ms
    return results

def parse_enumerate(output: str) -> dict[str, float]:
    """Parse enumerate results: size -> ms"""
    results = {}
    pattern = r"enumerate\((\d+M)\)\.reduce\(\):\s+([\d.]+)\s+ms"
    for match in re.finditer(pattern, output):
        size = match.group(1)
        ms = float(match.group(2))
        results[size] = ms
    return results

def format_diff(blitz: float, rayon: float, lower_is_better: bool = True) -> str:
    """Format the difference between Blitz and Rayon"""
    if rayon == 0:
        return "N/A"

    ratio = blitz / rayon
    if lower_is_better:
        if ratio < 1:
            diff = (1 - ratio) * 100
            return f"{Colors.GREEN}{diff:+.1f}% faster{Colors.ENDC}"
        else:
            diff = (ratio - 1) * 100
            return f"{Colors.RED}{diff:+.1f}% slower{Colors.ENDC}"
    else:
        if ratio > 1:
            diff = (ratio - 1) * 100
            return f"{Colors.GREEN}{diff:+.1f}% better{Colors.ENDC}"
        else:
            diff = (1 - ratio) * 100
            return f"{Colors.RED}{diff:+.1f}% worse{Colors.ENDC}"

def print_header(title: str):
    """Print a section header"""
    print()
    print(f"{Colors.BOLD}{'─' * 90}{Colors.ENDC}")
    print(f"{Colors.BOLD}{title}{Colors.ENDC}")
    print(f"{Colors.BOLD}{'─' * 90}{Colors.ENDC}")

def print_table_header(cols: list[tuple[str, int]]):
    """Print table header with columns"""
    header = "│"
    separator = "├"
    for name, width in cols:
        header += f" {name:^{width}} │"
        separator += "─" * (width + 2) + "┼"
    separator = separator[:-1] + "┤"
    print("┌" + "─" * (sum(w + 3 for _, w in cols) - 1) + "┐")
    print(header)
    print(separator)

def print_table_row(values: list[str], widths: list[int]):
    """Print a table row"""
    row = "│"
    for val, width in zip(values, widths):
        # Strip ANSI codes for width calculation
        clean_val = re.sub(r'\033\[[0-9;]*m', '', val)
        padding = width - len(clean_val)
        row += f" {val}{' ' * padding} │"
    print(row)

def print_table_footer(widths: list[int]):
    """Print table footer"""
    print("└" + "─" * (sum(w + 3 for w in widths) - 1) + "┘")

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))

    print(f"\n{Colors.BOLD}{'═' * 90}{Colors.ENDC}")
    print(f"{Colors.BOLD}              BLITZ vs RAYON COMPARATIVE BENCHMARK{Colors.ENDC}")
    print(f"{Colors.BOLD}{'═' * 90}{Colors.ENDC}\n")

    # Build both
    if not build_blitz(script_dir):
        sys.exit(1)
    if not build_rayon(script_dir):
        sys.exit(1)

    print()

    # Run both
    blitz_output = run_blitz(script_dir)
    rayon_output = run_rayon(script_dir)

    if not blitz_output or not rayon_output:
        print(f"{Colors.RED}Failed to run benchmarks{Colors.ENDC}")
        sys.exit(1)

    # Parse results
    print(f"\n{Colors.BOLD}{'═' * 90}{Colors.ENDC}")
    print(f"{Colors.BOLD}                              COMPARISON RESULTS{Colors.ENDC}")
    print(f"{Colors.BOLD}{'═' * 90}{Colors.ENDC}")

    # 1. Fork-Join Overhead
    print_header("1. FORK-JOIN OVERHEAD (ns/fork, lower is better)")
    blitz_fj = parse_fork_join(blitz_output)
    rayon_fj = parse_fork_join(rayon_output)

    cols = [("Depth", 8), ("Blitz", 12), ("Rayon", 12), ("Difference", 20)]
    widths = [w for _, w in cols]
    print_table_header(cols)

    for depth in sorted(set(blitz_fj.keys()) | set(rayon_fj.keys())):
        b = blitz_fj.get(depth, 0)
        r = rayon_fj.get(depth, 0)
        diff = format_diff(b, r) if b and r else "N/A"
        print_table_row([str(depth), f"{b:.2f}", f"{r:.2f}", diff], widths)

    print_table_footer(widths)

    # 2. Parallel Fibonacci
    print_header("2. PARALLEL FIBONACCI (ms, lower is better)")
    blitz_fib = parse_fib(blitz_output)
    rayon_fib = parse_fib(rayon_output)

    cols = [("N", 6), ("Blitz (ms)", 12), ("Rayon (ms)", 12), ("Blitz Speedup", 14), ("Rayon Speedup", 14), ("Difference", 20)]
    widths = [w for _, w in cols]
    print_table_header(cols)

    for n in sorted(set(blitz_fib.keys()) | set(rayon_fib.keys())):
        b_ms, b_sp = blitz_fib.get(n, (0, 0))
        r_ms, r_sp = rayon_fib.get(n, (0, 0))
        diff = format_diff(b_ms, r_ms) if b_ms and r_ms else "N/A"
        print_table_row([str(n), f"{b_ms:.1f}", f"{r_ms:.1f}", f"{b_sp:.1f}x", f"{r_sp:.1f}x", diff], widths)

    print_table_footer(widths)

    # 3. Parallel Sum
    print_header("3. PARALLEL SUM (ms, lower is better)")
    blitz_sum = parse_sum(blitz_output)
    rayon_sum = parse_sum(rayon_output)

    cols = [("Size", 8), ("Blitz (ms)", 12), ("Rayon (ms)", 12), ("Difference", 20)]
    widths = [w for _, w in cols]
    print_table_header(cols)

    for size in ["1M", "10M", "100M"]:
        b_ms, _ = blitz_sum.get(size, (0, 0))
        r_ms, _ = rayon_sum.get(size, (0, 0))
        diff = format_diff(b_ms, r_ms) if b_ms and r_ms else "N/A"
        print_table_row([size, f"{b_ms:.2f}", f"{r_ms:.2f}", diff], widths)

    print_table_footer(widths)

    # 4. PDQSort Patterns
    print_header("4. PDQSORT ON DIFFERENT PATTERNS - 1M elements (ms, lower is better)")
    blitz_pdq = parse_pdqsort_patterns(blitz_output)
    rayon_pdq = parse_pdqsort_patterns(rayon_output)

    cols = [("Pattern", 12), ("Blitz (ms)", 12), ("Rayon (ms)", 12), ("Difference", 20)]
    widths = [w for _, w in cols]
    print_table_header(cols)

    for pattern in ["Random", "Sorted", "Reverse", "All equal"]:
        b = blitz_pdq.get(pattern, 0)
        r = rayon_pdq.get(pattern, 0)
        diff = format_diff(b, r) if b and r else "N/A"
        print_table_row([pattern, f"{b:.1f}", f"{r:.1f}", diff], widths)

    print_table_footer(widths)

    # 5. Find Operations
    print_header("5. FIND OPERATIONS (μs, lower is better)")
    blitz_find = parse_find(blitz_output)
    rayon_find = parse_find(rayon_output)

    cols = [("Operation", 20), ("Blitz (μs)", 12), ("Rayon (μs)", 12), ("Difference", 20)]
    widths = [w for _, w in cols]
    print_table_header(cols)

    for key in sorted(set(blitz_find.keys()) | set(rayon_find.keys())):
        b = blitz_find.get(key, 0)
        r = rayon_find.get(key, 0)
        diff = format_diff(b, r) if b and r else "N/A"
        print_table_row([key, f"{b:.1f}", f"{r:.1f}", diff], widths)

    print_table_footer(widths)

    # 6. Any/All
    print_header("6. ANY/ALL PREDICATES - 10M elements (μs, lower is better)")
    blitz_aa = parse_any_all(blitz_output)
    rayon_aa = parse_any_all(rayon_output)

    cols = [("Operation", 18), ("Blitz (μs)", 12), ("Rayon (μs)", 12), ("Difference", 20)]
    widths = [w for _, w in cols]
    print_table_header(cols)

    for key in sorted(set(blitz_aa.keys()) | set(rayon_aa.keys())):
        b = blitz_aa.get(key, 0)
        r = rayon_aa.get(key, 0)
        diff = format_diff(b, r) if b and r else "N/A"
        print_table_row([key, f"{b:.1f}", f"{r:.1f}", diff], widths)

    print_table_footer(widths)

    # 7. MinByKey
    print_header("7. MIN BY KEY (ms, lower is better)")
    blitz_mbk = parse_minbykey(blitz_output)
    rayon_mbk = parse_minbykey(rayon_output)

    cols = [("Size", 8), ("Blitz (ms)", 12), ("Rayon (ms)", 12), ("Difference", 20)]
    widths = [w for _, w in cols]
    print_table_header(cols)

    for size in ["1M", "10M"]:
        b_ms, _ = blitz_mbk.get(size, (0, 0))
        r_ms, _ = rayon_mbk.get(size, (0, 0))
        diff = format_diff(b_ms, r_ms) if b_ms and r_ms else "N/A"
        print_table_row([size, f"{b_ms:.2f}", f"{r_ms:.2f}", diff], widths)

    print_table_footer(widths)

    # 8. Chunks
    print_header("8. CHUNKS ITERATOR - 10M elements (ms, lower is better)")
    blitz_chunks = parse_chunks(blitz_output)
    rayon_chunks = parse_chunks(rayon_output)

    cols = [("Chunk Size", 12), ("Blitz (ms)", 12), ("Rayon (ms)", 12), ("Difference", 20)]
    widths = [w for _, w in cols]
    print_table_header(cols)

    for chunk_size in sorted(set(blitz_chunks.keys()) | set(rayon_chunks.keys())):
        b = blitz_chunks.get(chunk_size, 0)
        r = rayon_chunks.get(chunk_size, 0)
        diff = format_diff(b, r) if b and r else "N/A"
        print_table_row([str(chunk_size), f"{b:.2f}", f"{r:.2f}", diff], widths)

    print_table_footer(widths)

    # 9. Enumerate
    print_header("9. ENUMERATE ITERATOR (ms, lower is better)")
    blitz_enum = parse_enumerate(blitz_output)
    rayon_enum = parse_enumerate(rayon_output)

    cols = [("Size", 8), ("Blitz (ms)", 12), ("Rayon (ms)", 12), ("Difference", 20)]
    widths = [w for _, w in cols]
    print_table_header(cols)

    for size in ["1M", "10M"]:
        b = blitz_enum.get(size, 0)
        r = rayon_enum.get(size, 0)
        diff = format_diff(b, r) if b and r else "N/A"
        print_table_row([size, f"{b:.2f}", f"{r:.2f}", diff], widths)

    print_table_footer(widths)

    # Summary
    print(f"\n{Colors.BOLD}{'═' * 90}{Colors.ENDC}")
    print(f"{Colors.BOLD}                                 SUMMARY{Colors.ENDC}")
    print(f"{Colors.BOLD}{'═' * 90}{Colors.ENDC}")
    print(f"""
  {Colors.GREEN}Green{Colors.ENDC} = Blitz is faster
  {Colors.RED}Red{Colors.ENDC}   = Rayon is faster

  Note: Results may vary based on system load and hardware.
  Both frameworks use work-stealing with similar thread counts.
""")

if __name__ == "__main__":
    main()
