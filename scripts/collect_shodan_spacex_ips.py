#!/usr/bin/env python3
"""Collect Shodan org:spacex results into country-grouped scan targets."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import shutil
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path


SHODAN_SEARCH_URL = "https://api.shodan.io/shodan/host/search"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Collect Shodan search IPs grouped by location.country_code."
    )
    parser.add_argument(
        "--query",
        default=os.environ.get("SHODAN_QUERY", "org:spacex"),
        help="Shodan search query to run.",
    )
    parser.add_argument(
        "--max-pages",
        type=int,
        default=int(os.environ.get("SHODAN_MAX_PAGES", "1")),
        help="Maximum Shodan result pages to fetch. Each page contains up to 100 results.",
    )
    parser.add_argument(
        "--targets-file",
        default="targets/spacex_ips.tsv",
        help="TSV file to write for the network trace workflow.",
    )
    parser.add_argument(
        "--by-country-dir",
        default="targets/by-country",
        help="Directory where per-country IP folders are written.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=30,
        help="HTTP timeout in seconds.",
    )
    return parser.parse_args()


def fetch_shodan_page(
    api_key: str, query: str, page: int, timeout: int
) -> dict[str, object]:
    params = urllib.parse.urlencode(
        {
            "key": api_key,
            "query": query,
            "page": str(page),
            "minify": "true",
        }
    )
    url = f"{SHODAN_SEARCH_URL}?{params}"
    request = urllib.request.Request(url, headers={"User-Agent": "spacex-ip-collector/1.0"})

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Shodan API returned HTTP {exc.code}: {body}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Could not reach Shodan API: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Shodan API returned invalid JSON: {exc}") from exc


def country_code_for(match: dict[str, object]) -> str | None:
    country_code = None
    location = match.get("location")
    if isinstance(location, dict):
        country_code = location.get("country_code")

    if not isinstance(country_code, str):
        country_code = match.get("country_code")

    if not isinstance(country_code, str):
        return None

    country_code = country_code.strip().upper()
    if len(country_code) != 2 or not country_code.isalpha():
        return None
    return country_code


def ip_for(match: dict[str, object]) -> str | None:
    ip_value = match.get("ip_str")
    if not isinstance(ip_value, str) and isinstance(match.get("ip"), int):
        ip_value = str(ipaddress.ip_address(match["ip"]))

    if not isinstance(ip_value, str):
        return None

    try:
        return str(ipaddress.ip_address(ip_value.strip()))
    except ValueError:
        return None


def collect_targets(
    api_key: str, query: str, max_pages: int, timeout: int
) -> tuple[dict[str, set[str]], int, int, int]:
    if max_pages < 1:
        raise ValueError("--max-pages must be at least 1")

    targets_by_country: dict[str, set[str]] = defaultdict(set)
    total_matches_seen = 0
    skipped_without_country = 0
    skipped_without_ip = 0

    for page in range(1, max_pages + 1):
        print(f"Fetching Shodan page {page} for query: {query}")
        response = fetch_shodan_page(api_key, query, page, timeout)
        matches = response.get("matches")
        if not isinstance(matches, list) or not matches:
            break

        for match in matches:
            if not isinstance(match, dict):
                continue

            total_matches_seen += 1
            country_code = country_code_for(match)
            ip_address = ip_for(match)

            if country_code is None:
                skipped_without_country += 1
                continue
            if ip_address is None:
                skipped_without_ip += 1
                continue

            targets_by_country[country_code].add(ip_address)

        total = response.get("total")
        if isinstance(total, int) and page * 100 >= total:
            break

        # Keep a small gap between paged requests to avoid hammering the API.
        time.sleep(1)

    return targets_by_country, total_matches_seen, skipped_without_country, skipped_without_ip


def ip_sort_key(ip_address: str) -> tuple[int, int]:
    parsed = ipaddress.ip_address(ip_address)
    return parsed.version, int(parsed)


def write_targets(
    targets_by_country: dict[str, set[str]],
    targets_file: Path,
    by_country_dir: Path,
    query: str,
) -> int:
    targets_file.parent.mkdir(parents=True, exist_ok=True)
    by_country_dir.parent.mkdir(parents=True, exist_ok=True)

    if by_country_dir.exists():
        shutil.rmtree(by_country_dir)
    by_country_dir.mkdir(parents=True, exist_ok=True)

    generated_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    target_rows: list[tuple[str, str]] = []

    for country_code in sorted(targets_by_country):
        ips = sorted(targets_by_country[country_code], key=ip_sort_key)
        country_dir = by_country_dir / country_code
        country_dir.mkdir(parents=True, exist_ok=True)
        (country_dir / "ips.txt").write_text("\n".join(ips) + "\n", encoding="utf-8")

        for ip_address in ips:
            target_rows.append((country_code, ip_address))

    with targets_file.open("w", encoding="utf-8") as file:
        file.write("# Generated from Shodan search results.\n")
        file.write(f"# Query: {query}\n")
        file.write(f"# Generated: {generated_at}\n")
        file.write("country_code\tip_address\n")
        for country_code, ip_address in target_rows:
            file.write(f"{country_code}\t{ip_address}\n")

    return len(target_rows)


def main() -> int:
    args = parse_args()
    api_key = os.environ.get("shodan_key")
    if not api_key:
        print("shodan_key environment variable is required.", file=sys.stderr)
        return 1

    targets_by_country, seen, skipped_country, skipped_ip = collect_targets(
        api_key,
        args.query,
        args.max_pages,
        args.timeout,
    )
    written = write_targets(
        targets_by_country,
        Path(args.targets_file),
        Path(args.by_country_dir),
        args.query,
    )

    print("Shodan SpaceX target collection complete.")
    print(f"Matches processed: {seen}")
    print(f"Unique IP targets written: {written}")
    print(f"Countries written: {len(targets_by_country)}")
    print(f"Skipped without country_code: {skipped_country}")
    print(f"Skipped without valid IP: {skipped_ip}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
