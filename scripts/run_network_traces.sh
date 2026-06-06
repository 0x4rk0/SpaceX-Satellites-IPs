#!/usr/bin/env bash
set -euo pipefail

targets_file="${1:-targets/spacex_ips.tsv}"
output_dir="${2:-traces}"
mtr_cycles="${MTR_CYCLES:-10}"

if [[ ! -f "$targets_file" ]]; then
  echo "Target file not found: $targets_file" >&2
  exit 1
fi

if command -v mtr >/dev/null 2>&1; then
  trace_tool="mtr"
elif command -v traceroute >/dev/null 2>&1; then
  trace_tool="traceroute"
else
  echo "Neither mtr nor traceroute is installed." >&2
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

has_localhost_hop() {
  local report_file="$1"

  grep -Eq '^[[:space:]]*[0-9]+([.)|][^[:space:]]*)?[[:space:]]+localhost([[:space:]]|\(|$)' "$report_file"
}

run_trace() {
  local ip_address="$1"

  if [[ "$trace_tool" == "mtr" ]]; then
    mtr -r -w -b -c "$mtr_cycles" "$ip_address"
  else
    traceroute "$ip_address"
  fi
}

append_report() {
  local country_code="$1"
  local ip_address="$2"
  local report_file="$3"
  local trace_status="$4"
  local country_dir="$output_dir/$country_code"
  local country_report="$country_dir/localhost-traces.txt"

  mkdir -p "$country_dir"

  if [[ ! -f "$country_report" ]]; then
    {
      echo "# localhost network traces for $country_code"
      echo "# Generated: $run_started_at"
      echo "# Input: $targets_file"
      echo "# Preferred tool: mtr when available, otherwise traceroute"
      echo "# MTR cycles: $mtr_cycles"
      echo
    } >"$country_report"
  fi

  {
    echo "===== target: $ip_address | country: $country_code | tool: $trace_tool | captured: $(date -u +"%Y-%m-%dT%H:%M:%SZ") | exit: $trace_status ====="
    cat "$report_file"
    echo
  } >>"$country_report"
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

  echo "Running $trace_tool for $ip_address ($country_code)..."
  set +e
  run_trace "$ip_address" >"$report_file" 2>&1
  trace_status=$?
  set -e

  if [[ "$trace_status" -ne 0 ]]; then
    failed_count=$((failed_count + 1))
  fi

  if has_localhost_hop "$report_file"; then
    append_report "$country_code" "$ip_address" "$report_file" "$trace_status"
    saved_count=$((saved_count + 1))
  else
    skipped_count=$((skipped_count + 1))
    echo "No localhost hostname found for $ip_address; trace not saved."
  fi
done <"$targets_file"

cat <<EOF
Network trace run complete.
Trace tool: $trace_tool
Targets processed: $target_count
Reports saved: $saved_count
Reports skipped without localhost: $skipped_count
Trace command failures: $failed_count
EOF
