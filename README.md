# orin-auth

Authentication and authorization for [orin-web](https://github.com/orin-lang/orin-web) applications, written in
[Orin](https://github.com/orin-lang/orin-lang). Passwords, sessions, CSRF protection, API tokens, JWT, an OpenID Connect relying
party, role and scope checks, and login rate limiting, as plain functions and orin-web middleware.

Status: version 0.1, pre-release, like the language. The cryptography is **temporary**: it runs on a pure-Orin SHA-256 until
`std:crypto` exists (see [docs/security.md](docs/security.md), "Cryptography"). Read that section before using this in production.

```ts
import { Router, Request, Response, WebError, withMiddleware, authenticate, sessionAuthenticator, apiTokenAuthenticator,
         requireRole, mixedAuthzConfig, currentPrincipal } from "orin-auth";

let app = new Router();
app.use(authenticate([apiTokenAuthenticator(tokens, "orbit"), sessionAuthenticator(sessions)], now));  // who is it?
app.use(csrf.middleware());                                                                            // is it forged?
app.get("/admin", withMiddleware(requireRole(mixedAuthzConfig("/login"), "admin"), adminPage));         // may they?
```

The complete application is [examples/web-login](examples/web-login) (login form with CSRF token, rate limit, session, role and scope
protected routes, API tokens, logout), tested with orin-web's `TestClient`.

## What is in it

| Area | API |
|---|---|
| Passwords | `hashPassword verifyPassword needsRehash verifyAndUpgrade dummyVerify`, PHC strings (`$pbkdf2-sha256$i=..$salt$hash`), `PasswordPolicy`. argon2id is parsed and compared but **deferred** (needs `std:crypto`) |
| Sessions | `SessionManager` (`login rotate lookup logout logoutSubject purgeExpired`), `SessionStore` interface, `MemorySessionStore`; opaque 256-bit ids, only SHA-256 of the id is stored; idle (sliding) + absolute expiry; new id on login |
| Cookies | `CookieAttrs`, `setCookieValue clearCookieValue requestCookie`; HttpOnly, Secure, SameSite=Lax by default, all configurable; `__Host-` / `__Secure-` rules enforced |
| CSRF | `CsrfProtection` middleware: signed double-submit token (session- or cookie-bound, fresh nonce per issue) or required custom header; Origin / Referer / `Sec-Fetch-Site` checks |
| API tokens | `issueApiToken verifyApiToken revokeApiToken`, `ApiTokenStore`, `MemoryApiTokenStore`; `<prefix>_<id>_<secret>`, stored hashed, scopes, expiry, constant-time comparison |
| JWT | `signJwt verifyJwt jwtAuthenticator`; HS256 signing and verification, exp / nbf / iss / aud with clock skew, `alg: none` and algorithm confusion rejected, `kid` key sets. RS256 / ES256 through `JwtExternalKey` verifier hooks (**deferred**: no RSA / ECDSA in std yet) |
| OIDC | `parseDiscovery beginLogin completeLogin parseJwks jwksKeys`; authorization code + PKCE S256 + state + nonce; HTTP client and ID-token validation are pluggable |
| Authorization | `Principal`, `authenticate`, `requireAuthenticated requireRole requireAnyRole requireScope requireAllScopes requirePrincipal`; 401 vs 403; JSON, redirect (`?next=`) or by `Accept`; `safeNext` |
| Rate limiting | `RateLimiter` (token bucket per key, bounded memory), `rateLimit` middleware (429 + `Retry-After`) |
| Annotations | `@Use("authenticated")`, `@Use("role:admin")`, `@Use("scope:deploy")` through `authMiddlewares`; see [docs/annotations.md](docs/annotations.md) |

## Using it

orin-auth is an Orin package. Until there is a registry, add it by path or Git, and depend on **orin-auth alone**: it re-exports the
orin-web names an application needs (two declarations of orin-web are two different packages to the compiler):

```sh
orin add --git https://github.com/orin-lang/orin-auth --rev COMMIT
```

```ts
import { Router, Request, Response, WebError, SessionManager, MemorySessionStore } from "orin-auth";
```

### Time and randomness are values

Expiry needs the wall clock and ids need OS entropy; both need a grant, and a closure (and so an orin-web handler) cannot hold one.
orin-auth therefore takes `NowFn = () => int` (milliseconds) and `RandomFn = (n: usize) => Result<Bytes, AuthError>` as arguments.
`startClock(scope, clockGrant)` and `startRandom(scope, fsGrant)` run them as small service tasks; tests use `fixedClock`,
`countingRandom` and `constantRandom`. Stores and the rate limiter are owner tasks started in a `scope` (`MemorySessionStore.start(s)`,
then `close()` before the scope ends), the same pattern as orin-web's `examples/todo-api`.

### A login handler

```ts
const checked = verifyAndUpgrade(password, user.phc, defaultPasswordPolicy(), random)?;   // Result<_, PasswordError>
match (checked) {
  PasswordRejected => { /* 401; for an unknown user call dummyVerify(password, policy) first */ },
  PasswordAcceptedRehashed(fresh) => { /* save `fresh` as the new hash, then continue */ },
  PasswordAccepted => {},
}
const made = sessions.login(req, now(), user.name, user.roles, user.scopes)?;     // new id, the old one is destroyed
return Ok(Response.redirect(303, "/")?.withAddedHeader("Set-Cookie", made.setCookie));
```

## Tests

```sh
tools/ci.sh        # ORIN=/path/to/orin to select the launcher
```

About 135 tests: known-answer tests for the SHA-256 / HMAC / PBKDF2 code (FIPS 180-4, RFC 4231, RFC 7914), the JWT vector of
RFC 7515 appendix A.1, the PKCE vector of RFC 7636 appendix B, and negative tests for tampered cookies and tokens, expired and
not-yet-valid tokens, wrong issuer / audience, `alg: none`, algorithm confusion, missing CSRF tokens, replayed OIDC callbacks.

## Security

[docs/security.md](docs/security.md) has the threat model, the design choices and the known limits.

MIT license.

## Module architecture

Implementation is organized into directory modules with explicit `module.or` interfaces and compiler-enforced dependency policies. See [the module map](docs/architecture.md) and run `ORIN=/path/to/orin tools/check_modules.sh` to verify the boundaries. The package-level imports remain compatible.
