# Library architecture

Use Orin directory modules. `src/module.or` is the package facade and contains only explicit re-exports. Implementation files belong inside cohesive subsystem directories, each with its own `module.or`. A collection of unrelated files under `src/` is not an acceptable library layout.

- `core/module.or`: error, principal, services.
- `crypto/module.or`: crypto, sha256.
- `storage/module.or`: kv.
- `sessions/module.or`: cookie, session, authn.
- `credentials/module.or`: password, apitoken, jwt.
- `protection/module.or`: authz, annotated, csrf, ratelimit.
- `oidc/module.or`: oidc.

Import sibling subsystems through their directory interface, never through implementation files. Within one module, units may import one another directly. Keep interfaces deliberate: expose only names needed by package consumers or another subsystem. Preserve the existing package API unless an API change is explicitly requested. Do not add compatibility files under `src/` to bypass module boundaries.

`orin.toml` declares allowed module dependencies. Keep the graph acyclic and respect its layers; a new dependency requires an architectural reason, not just a compiler workaround. New subsystems need both a `module.or` and a manifest policy. Do not broaden dependency allowlists or move implementation into the package facade just to make a test pass.

Run `ORIN=/path/to/current/orin tools/check_modules.sh` and the repository test entry point before completing changes. Architecture checks preserve the explicit package export names (`api/public-names.txt`), type-check the dependency graph, and verify compiler rejection of private-file imports (E0302) and forbidden dependencies (E0501). Update the export snapshot only for a deliberate public API change; it is not a substitute for type-checking and behavioral tests.
