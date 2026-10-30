# Service catalogue

These files are the services VPN Bypass ships: one JSON file per category. The Services page lists the services a user has on, and the **Browse catalogue…** sheet offers the rest. The files are bundled inside the signed app; nothing is downloaded.

## Policy

**The service catalogue is best effort.** It gives each user a sensible starting point, not a complete or always-current list. We avoid constant changes to it: no pull requests that chase every CDN host or domain shuffle, and no churn.

We accept two kinds of change:

- a new service in a clear category;
- a fix for a domain that no longer works.

Each user is expected to adjust a service as needed: add names to a built-in service from the DNS Lookups page or the Services page, or make a custom service. That is preferred over editing the catalogue.

Ids never change. Saved configs, `vpnb` and the MCP server refer to them.

## File format

The file name is its category: `video.json` holds `"category": "video"`.

```json
{
  "category": "banks",
  "services": [
    { "id": "fr_lcl", "name": "LCL", "region": "FR", "domains": ["*.lcl.fr"] }
  ]
}
```

| Field | Required | What it holds |
|---|---|---|
| `id` | yes | `a-z`, `0-9` and `_`. Never starts with `custom_`. Unique across all files. Never changes once shipped. |
| `name` | yes | The service's proper name, not translated. It is also the name its routes are listed under, so it must differ from every other name, ignoring case and spaces. |
| `domains` | yes | Plain names (`example.com`) or wildcards (`*.example.com`). |
| `ipRanges` | no | IPv4 ranges such as `91.108.4.0/22`. |
| `region` | no | An ISO 3166 country code (`FR`) for a service that belongs to one country. The sheet shows it and search matches it. |

A service needs at least one domain or range.

## Adding a service

- Put it in the file of its category. A new category needs a case in `ServiceCatalogue.Category` (`Sources/VPNBypassCore/ServiceCatalogue.swift`) and its name in English, Spanish and French (`Resources/*.lproj/Localizable.strings`).
- Prefer one wildcard over the site's own domain (`*.example.fr`) to a list of hosts. The app refuses a wildcard over a top-level domain or a shared suffix (`*.com`, `*.co.uk`, `*.cloudfront.net`).
- One service per bank or brand, so each user picks theirs.
- Check that each domain still resolves.
- Add the new id to `frozenIds` in `Tests/VPNBypassTests/ServiceCatalogueTests.swift`.
- One pull request.

## The check

`swift test --filter ServiceCatalogueTests` reads every file with the app's own validators and fails on bad JSON, an unknown field or category, a repeated id or name, an invalid domain, wildcard, range or region, and a service with nothing in it. CI runs it in the `test` job.

A merged change ships in the next release: anything under `Sources/` starts one.
