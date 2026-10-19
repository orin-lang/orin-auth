# Module architecture

`src/module.or` preserves the package API. Each subsystem below has a separate, explicit `module.or` interface; consumers inside the library import that directory, while its implementation units remain private.

- `core/module.or`: error, principal, services.
- `crypto/module.or`: crypto, sha256.
- `storage/module.or`: kv.
- `sessions/module.or`: cookie, session, authn.
- `credentials/module.or`: password, apitoken, jwt.
- `protection/module.or`: authz, annotated, csrf, ratelimit.
- `oidc/module.or`: oidc.

The allowed dependency edges are recorded in `orin.toml` and enforced by the compiler. `orin check --deps` prints the graph. `tools/check_modules.sh` additionally rejects flat implementation files, checks package export compatibility, and compiles negative probes that must fail with E0302 (private unit) and E0501 (forbidden dependency).

Tests outside `src/` use the package interface. Tests of non-public helpers live within the owning module and are invoked explicitly by the test script. The layout does not change the package import name or the behavior of exported functions.
