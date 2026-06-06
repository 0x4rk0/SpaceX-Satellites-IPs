#!/usr/bin/env bash
set -euo pipefail

targets_file="${1:-targets/spacex_ips.tsv}"
output_dir="${2:-spacex_sat_ips}"

if [[ ! -f "$targets_file" ]]; then
  echo "Target file not found: $targets_file" >&2
  exit 1
fi

if ! command -v traceroute >/dev/null 2>&1; then
  echo "traceroute is not installed." >&2
  exit 1
fi

mkdir -p "$output_dir"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

run_started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
target_count=0
saved_count=0
skipped_count=0
failed_count=0

extract_sat_ips_before_target() {
  local report_file="$1"
  local target_ip="$2"

  python3 - "$report_file" "$target_ip" <<'PY'
import ipaddress
import re
import sys

report_path = sys.argv[1]
target_ip = str(ipaddress.ip_address(sys.argv[2]))
ip_pattern = re.compile(
    r"\(([^)]+)\)|"
    r"(?<![A-Za-z0-9:])(\d{1,3}(?:\.\d{1,3}){3}|[0-9A-Fa-f]{0,4}:[0-9A-Fa-f:.]+)(?![A-Za-z0-9:])"
)
hop_ips = []

with open(report_path, encoding="utf-8", errors="replace") as report:
    for line in report:
        if not re.match(r"^\s*\d+\s+", line):
            continue

        for match in ip_pattern.finditer(line):
            candidate = (match.group(1) or match.group(2) or "").strip("[]")
            try:
                ip = str(ipaddress.ip_address(candidate))
            except ValueError:
                continue

            if not hop_ips or hop_ips[-1] != ip:
                hop_ips.append(ip)

try:
    target_index = hop_ips.index(target_ip)
except ValueError:
    sys.exit(2)

sat_ips = hop_ips[max(0, target_index - 2):target_index]
if len(sat_ips) != 2:
    sys.exit(3)

print("\t".join(sat_ips))
PY
}

run_trace() {
  local ip_address="$1"

  traceroute "$ip_address"
}

append_sat_ips() {
  local country_code="$1"
  local target_ip="$2"
  local sat_ip_1="$3"
  local sat_ip_2="$4"
  local trace_status="$5"
  local country_dir="$output_dir/$country_code"
  local country_ips="$country_dir/ips.txt"
  local country_targets="$country_dir/targets.tsv"

  mkdir -p "$country_dir"

  if [[ ! -f "$country_targets" ]]; then
    {
      echo "# SpaceX satellite IP candidates for $country_code"
      echo "# Generated: $run_started_at"
      echo "# Input: $targets_file"
      echo "# Extracted from the two traceroute hop IPs immediately before each scanned target IP."
      printf 'target_ip\tsat_ip_1\tsat_ip_2\tcaptured_at\ttraceroute_exit\n'
    } >"$country_targets"
  fi

  printf '%s\n%s\n' "$sat_ip_1" "$sat_ip_2" >>"$country_ips"
  sort -u "$country_ips" -o "$country_ips"

  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$target_ip" \
    "$sat_ip_1" \
    "$sat_ip_2" \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    "$trace_status" >>"$country_targets"
}

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  line="${raw_line%%#*}"
  line="${line//$'\r'/}"
  line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"

  [[ -z "$line" ]] && continue
  [[ "$line" == country_code* ]] && continue

  IFS=$' \t,' read -r country_code ip_address _rest <<<"$line"
  country_code="$(printf '%s' "$country_code" | tr '[:lower:]' '[:upper:]')"

  if [[ ! "$country_code" =~ ^[A-Z]{2}$ || -z "${ip_address:-}" ]]; then
    echo "Skipping invalid target line: $raw_line" >&2
    continue
  fi

  target_count=$((target_count + 1))
  report_file="$tmp_dir/${country_code}_${target_count}.txt"

  echo "Running traceroute for $ip_address ($country_code)..."
  set +e
  run_trace "$ip_address" >"$report_file" 2>&1
  trace_status=$?
  set -e

  if [[ "$trace_status" -ne 0 ]]; then
    failed_count=$((failed_count + 1))
  fi

  set +e
  sat_ips="$(extract_sat_ips_before_target "$report_file" "$ip_address")"
  extract_status=$?
  set -e

  if [[ "$extract_status" -eq 0 ]]; then
    IFS=$'\t' read -r sat_ip_1 sat_ip_2 <<<"$sat_ips"
    append_sat_ips "$country_code" "$ip_address" "$sat_ip_1" "$sat_ip_2" "$trace_status"
    saved_count=$((saved_count + 1))
  else
    skipped_count=$((skipped_count + 1))
    echo "Could not find two hop IPs immediately before target $ip_address; satellite IPs not saved."
  fi
done <"$targets_file"

cat <<EOF
Traceroute satellite IP discovery complete.
Targets processed: $target_count
Targets with satellite IPs saved: $saved_count
Targets skipped without two preceding hop IPs: $skipped_count
Traceroute command failures: $failed_count
EOF
