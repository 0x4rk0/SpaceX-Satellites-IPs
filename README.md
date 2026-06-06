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

Use two-letter ISO 3166-1 alpha-2 country codes. The workflow writes matching
reports to `traces/<ISO>/localhost-traces.txt`.

## Run traces

The workflow runs manually from **Actions > SpaceX localhost network traces > Run workflow**.
It also runs when the target list, workflow, or runner script changes.

The workflow uses GitHub's free `ubuntu-latest` hosted runner. It prefers `mtr`
when that tool is already available; otherwise it uses `traceroute`.

Only trace reports containing a hop whose hostname is exactly `localhost` are
stored. Those `localhost` hostname hits are treated as SpaceX IP results.
