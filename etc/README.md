# `etc/` configuration layout

One ignored `etc/setup.env` holds all non-secret local settings (copy from
`etc/setup.env.example`; never commit it). It is the only env file
`bin/lib/common.sh` loads; environment exports win over its values.

Service `*.env.example` files (`synthea`, `webapi`, `mcp`) are documentation
only — reference for which knobs exist and their defaults. Never create
`etc/<service>.env` files; `common.sh` does not read them.

Secrets live under `<data-root>/secrets/` (mode `0600`, never committed) and
reach containers as Docker secrets via `/run/secrets/*` + `*_PASSWORD_FILE`.
They are never printed, logged, or committed.
