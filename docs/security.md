# Security: threat model and design choices

## Scope

orin-auth protects an orin-web application against an **unauthenticated network attacker**, a **malicious web page** that makes a
victim's browser send requests (CSRF), an attacker who can **read the stores** (database dump, backup, log) and an attacker who
**guesses** credentials. It does not protect against a compromised server process (it holds the keys), a malicious dependency, XSS in
your own pages (HttpOnly keeps the session cookie out of scripts, but an XSS can still act as the user), or an attacker who can read
process memory. TLS is the deployment's job (a proxy or the platform); orin-auth assumes the browser reaches the app over HTTPS and
sets `Secure` on every cookie by default.

## Cryptography (read this first)

`std:crypto` does not exist yet. orin-auth reaches every primitive through ONE module, `src/internal/crypto.or`, whose names
are the ones expected from `std:crypto` (`sha256`, `hmacSha256`, `pbkdf2HmacSha256`, `constantTimeEquals`, base64url). Until then that
module contains pure-Orin implementations of the **standard algorithms only** (FIPS 180-4 SHA-256, RFC 2104 HMAC, RFC 8018 PBKDF2),
verified against published vectors (`src/internal/crypto_test.or`); no construction of our own. Consequences:

* **Speed.** Orin has no bitwise operators, so XOR is a 64K table lookup and rotations are divisions. One SHA-256 block takes about 12
  microseconds, one PBKDF2 iteration about 25. The default of **20,000 PBKDF2 iterations (about half a second)** is therefore below
  OWASP's 600,000 for PBKDF2-HMAC-SHA-256; it is one number (`pbkdf2DefaultIterations` in `internal/crypto.or`). When `std:crypto` is
  native, raise it or switch the policy to argon2id: `needsRehash` / `verifyAndUpgrade` then re-hash every password at its next login.
* **Side channels.** Table lookups depend on data, so the pure-Orin SHA-256 is not cache-timing safe. It is only applied to inputs where this
  does not matter for the attacker model here: random session ids and tokens (the attacker does not choose, and cannot repeat,
  a secret input), and HMAC keys that live on the server. Comparisons of secrets (MACs, hashes, CSRF tokens) use `constantTimeEquals`,
  which visits every byte and has no data-dependent branch; this property is also best effort in a language without constant-time guarantees.
* **Passwords hashed with a memory-hard function.** argon2id (PHC strings are parsed, policies compare it, hashing returns
  `UnsupportedAlgorithm`) is **deferred** until `std:crypto`.
* **Randomness** comes from /dev/urandom through a service task (`startRandom`), the only OS entropy reachable. If it is not running, id
  creation returns `Err(EntropyFailed)`; nothing falls back to a weaker source. `RandomFn` is the seam for `std:crypto`'s source.

## Passwords

* PHC strings are self-describing, so the algorithm and cost can change without a schema change; `needsRehash` compares a stored hash
  with the current policy (algorithm, cost, salt and hash length).
* A 16 byte random salt per hash; a 32 byte derived key; verification compares in constant time.
* A wrong password and an unknown user must look alike: `dummyVerify` spends the time of a real verification, and the example answers
  both with the same 401 text.
* Stored parameters are bounded when verifying (at most 10 million iterations; salt and hash 8..64 bytes), so a corrupted row cannot pin a
  CPU. A password over 1024 bytes is refused, not truncated.
* No Unicode normalisation (std has none): normalise (NFKC) before calling if your users type non-ASCII passwords.
* Rate limiting (below) is what limits online guessing; hashing only limits offline guessing.

## Sessions

* **Id**: 256 random bits, base64url. It carries nothing. The server never accepts an id it did not create.
* **Store**: keyed by SHA-256(id). Stealing the store gives hashes, not cookies. The in-memory store is one owner task (atomic per command).
* **Fixation**: `login` mints a new id and deletes the presented one; `rotate` does the same after a privilege change.
* **Expiry**: idle timeout (default 30 min) that slides on use, written back at most every 60 s; absolute timeout (12 h) that never slides. The
  idle expiry is capped by the absolute one. Expired records are removed when met and by `purgeExpired`.
* **Cookie**: `__Host-sid`, `Secure; HttpOnly; SameSite=Lax; Path=/`, host-only; all attributes configurable, and the configuration is checked
  (`__Host-` needs Secure, Path=/ and no Domain; `SameSite=None` needs Secure). Lax lets top-level navigation from other sites carry the cookie
  (links keep working) and blocks it on cross-site POSTs; CSRF protection is still required for defence in depth and for same-site attackers.
* **Logout** removes the server record, so a copied cookie is dead; `logoutSubject` ends every session of a user.
* Not done: binding a session to an IP or user agent (it breaks mobile users and proxies and adds little); "remember me" tokens (use an API
  token with a long expiry, or a persistent cookie with `persistent: true`).

## CSRF

State-changing requests (not GET, HEAD, OPTIONS, TRACE) must prove they come from our pages:

* **Token mode**: `nonce(16) || HMAC-SHA-256(key, "orin-auth csrf v1|" binding "|" nonce)`. The binding is the session (before login: a random
  `__Host-csrf` cookie), so a token works only for the browser that received it. Stateless; a new nonce per issue so page sizes do not leak
  a stable secret (BREACH). Sent in `X-CSRF-Token` or the `csrf_token` form field.
* **Header mode**: a required custom header (`X-Requested-With`): a cross-site page cannot add it without a CORS preflight that you would have
  to allow. For JSON APIs called by your own script.
* Both: `Sec-Fetch-Site: cross-site` is refused; `Origin` (else `Referer`) must be in `allowedOrigins` or match `Host`; `requireOrigin` demands
  one of them.
* Exempt by default: requests with an `Authorization` header (a browser never adds it by itself, so such a request does not ride on cookies).
  Everything else, including the login form (login CSRF), is protected. `skip` exempts more (a webhook with its own signature).
* Not a defence against XSS: a script in your page can read a token. Fix the XSS.
* **CORS is not CSRF protection** and orin-auth does not configure it; if you use orin-web's `cors` with credentials, list exact origins.

## API tokens

`<prefix>_<24 hex id>_<43 base64url secret>`. The prefix lets secret scanners and humans recognise leaks and lets the authenticator ignore
bearer credentials that are not API tokens. The secret has 256 bits; only SHA-256(secret) is stored (a fast hash is right here because the
input is random, not a password). Verification compares in constant time and does the same work for an unknown id. Expiry and revocation are
decided after the secret is checked, so only a holder learns the reason. Scopes are granted at issue time and never widen. Show the token once.

## JWT

HS256 verification is a **verifier for tokens you or a peer service issued**, not a session replacement: JWTs cannot be revoked before they
expire. Use short lifetimes. The checks, in order, are in the header of `src/jwt.or`; the points that matter:

* `alg: none` is refused in any spelling, even if the application lists every algorithm. Unknown algorithms (HS384, PS256, ...) are refused.
* **Algorithm confusion**: the verifier's allow-list AND the selected key's own algorithm must match the header; an HMAC key never verifies an
  RS256 token and a public key is never used as an HMAC secret. A key set is typed (`JwtSecret` vs `JwtExternalKey`).
* Keys come only from the key set. `jwk`, `jku`, `x5u`, `x5c` in a header are ignored; `crit` is refused. A JWKS document can never add a
  symmetric key.
* The payload is parsed only after the signature verified. Header duplicates are refused (strict JSON), parts must be canonical unpadded
  base64url, tokens over 8 KiB are refused.
* `exp` is required by default; NumericDates must be integers; `leewaySeconds` (60) is the clock skew; `iss` and `aud` are checked when
  configured. **Set `audience`**: without it a token minted for another of your services is accepted.
* HS256 keys must be at least 32 bytes (RFC 7518 3.2): use random bytes, not a passphrase.
* **RS256 / ES256 are deferred**: verification needs RSA / ECDSA. The hook (`JwtExternalKey(kid, alg, verifier)`) shares every other check.

## OpenID Connect

Authorization code with PKCE S256 (the method `plain` is never sent), 256-bit `state` and `nonce`, a transaction that is single use, expires in 10
minutes and is bound to the browser by a `Max-Age=600` cookie (protects against login CSRF and state injection). The ID token must carry our client
id in `aud` (and `azp` when there are several), the provider's `iss`, and our `nonce`. The discovery document's `issuer` must equal the one asked for
and all endpoints must be https. Confidential clients use `client_secret_basic`.

**Pluggable parts**: HTTP (no client and no TLS in std; OIDC is https-only) and ID-token validation (RS256 needs `std:crypto`). Without them the flow
can be driven and tested end to end but not run against a real provider. After `completeLogin` the application creates its own session
(`SessionManager.login`), so session handling is the same for every login method.

## Authorization

401 means no principal, 403 a principal without the role or scope; they are never mixed up. The principal is a request **attribute** set only by
`authenticate`, which first clears any principal, so no header, cookie or earlier middleware can inject one. A request that presents a bad bearer
credential is a 401 even on a public route (it is never silently anonymous). Roles and scopes are exact, case-sensitive strings; a role does not
imply a scope. `safeNext` rejects open redirects (`//host`, `/\host`, absolute URLs, control characters).

## Rate limiting

A token bucket per key in one owner task (atomic). Memory is bounded: idle (full) buckets are swept, and when the table is still full a new key
is refused (fail closed). Per process; keys are chosen by the application (user name, forwarded address header set by your proxy: orin-web's
`Request` has no peer address, so the middleware cannot guess one). Limit by user name AND by client address if you can: a limit per user name
alone lets an attacker lock a user out (the example resets the bucket on success and answers 429 with `Retry-After`).

## Known limits

* **No server in the example.** A server needs a `NetGrant`, sessions need the wall clock (`ClockGrant`) and ids need entropy (`FsGrant`), and
  Orin cannot yet put grants of three families into one task scope: a closure cannot capture a grant and each scope function hands its body only
  its own family. `examples/web-login` therefore runs the application through `TestClient` with real entropy; orin-auth takes clock and
  randomness as function values so that a host that can provide them serves it unchanged. (Repro in the pull request.)
* One copy of orin-web: an application that lists orin-web and orin-auth gets two incompatible `Request` types. Depend on orin-auth only;
  it re-exports what an application needs.
* In-memory stores are lost on restart and are per process. Implement `SessionStore` / `ApiTokenStore` over a database for several instances.
* Everything runs in the app's address space: there is no separate privilege domain for the keys.
* Deferred, each waiting on `std:crypto` or a client: argon2id, SHA-512 (HS512 / RS512), HKDF, RS256 / ES256 verification, an HTTP client for
  OIDC discovery and JWKS fetching, WebAuthn, TOTP.
