# SpaceX-Satellites-IPs

This repository includes a GitHub Actions workflow that runs network traces
against the SpaceX IP targets listed in `targets/spacex_ips.tsv`.

## Add targets

Add targets as tab-, space-, or comma-separated rows:

```text
country_code	ip_address
US	203.0.113.10
CA	2001:db8::10
```

Use two-letter ISO 3166-1 alpha-2 country codes. The workflow writes discovered
satellite IP candidates to `spacex_sat_ips/<ISO>/ips.txt`.

## Collect targets from Shodan

Add a repository secret or environment secret named `shodan_key`, then run
**Actions > Collect Shodan SpaceX IPs > Run workflow**. The `max_pages` input
controls how many Shodan result pages are fetched. Each page contains up to 100
results. The collector searches Shodan for:

```text
org:spacex
```

It writes the scan input file to `targets/spacex_ips.tsv` and writes country
breakdowns to `targets/by-country/<ISO>/ips.txt`. After the collector completes
successfully, the network trace workflow runs against the generated target list.

## Run traces

The workflow runs manually from **Actions > SpaceX satellite IP discovery > Run workflow**.
It also runs after the Shodan collector succeeds, and when the target list,
workflow, or runner script changes.

The workflow uses GitHub's free `ubuntu-latest` hosted runner and runs
`traceroute` against each target.

For each target, the script finds the target IP in the traceroute hop list and
saves the two hop IPs immediately before it as SpaceX satellite IP candidates.
Unique candidates are stored in `spacex_sat_ips/<ISO>/ips.txt`, with target-level
details in `spacex_sat_ips/<ISO>/targets.tsv`.
