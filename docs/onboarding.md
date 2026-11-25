# Invited onboarding (Mac source build 121, first slice)

A signed-in user can start a new NStack workspace from a capped group invitation: choose a workspace name, optionally an
agent from the Tower's versioned catalogue, a funding amount (US$21 / 50 / 100 or a custom amount of at least US$21),
review, pay in Stripe **test mode**, and have the Tower create the workspace. Existing manual connections are untouched.

This slice is **workspace-only and test-mode**. See "Known gaps" before treating it as launch-ready.

## Contract used

NStack `/api/v4/onboarding` (tower `docs/contract/onboarding-v1.md`, `src/routes/onboarding.ts`, `src/services/onboarding.ts`),
human direct-signature NIP-98 only. Native uses: `GET/POST /account`, `GET /agent-offers`, `GET/POST /intents`,
`GET /intents/{id}`, `POST /intents/{id}/options|cancel|checkout|provision`. It does **not** call `GET /invites/{code}`
(the code would sit in a URL path), any `/admin` route. Lightning and top-ups are described in "Lightning and repeat top-ups" below.

* Every mutation sends a JSON body, at least `{}`: the Tower's strict check requires a NIP-98 `payload` hash even on
  bodiless actions. Reads send none.
* The Tower rollout gate (`ONBOARDING_ENABLED`) is invisible to reads, so "not switched on" is learned from the first
  mutation (`503 onboarding_rollout_disabled`) and shown as such. A Tower without the router answers 404 with no code and is
  shown as "does not offer invited onboarding".

## Code map

| File | Role |
| --- | --- |
| `AmbulandoCore/.../Onboarding/OnboardingModels.swift` | Wire types, funding presets/custom parsing, name rules |
| `.../OnboardingInvite.swift` | Redacted `OnboardingInviteCode`; parse of a pasted code or link |
| `.../OnboardingAPI.swift` | Signed client and `OnboardingFailure` classification |
| `.../OnboardingDraftStore.swift` | Durable draft per (Tower origin, signer); file and in-memory stores |
| `.../OnboardingController.swift` | Resumable actor: phases, review gate, checkout, provision, reconcile |
| `Ambulando/App/AppModel+Onboarding.swift` | `OnboardingModel` view-model, factory, return-URL config |
| `Ambulando/Views/OnboardingViews.swift` | `OnboardingEntry` (Connect and Settings) and `OnboardingFlowView` |
| `AmbulandoCore/Tests/.../Onboarding*.swift` | `FakeOnboardingTower` plus 28 tests |

## Rules the controller enforces

* **Origin before signing.** The Tower's own `/.well-known/nstack.json` must name the same HTTPS origin and advertise NIP-98
  before any signed request is sent. A pasted link only *suggests* an origin; a different one is refused, never contacted.
* **Identity scope.** Drafts are keyed by hash of (origin, signer npub) and re-checked on load. The controller refuses to
  act unless the unlocked key is the signer it was built for. The server returns a neutral 404 for another identity's intent;
  the client then drops its pointer and rotates keys rather than reusing anything.
* **Invitation secrecy.** The code appears only in the create-intent body and the device-only draft file (no backup, complete
  file protection on iOS), and is deleted from the draft once the intent id is stored. It prints as `inv_••••`.
* **Review gate.** Nothing is created or charged until the user confirms the review screen; checkout additionally requires the
  reviewed digest to equal the server intent's own choices, so a reconciled change forces a fresh review.
* **Payment truth.** Only a server intent with `funded && !funding_reversed` and a funded/provisioning/provisioned status is
  treated as paid. A return to the app, a browser message or the return URL never funds; a return not matching the configured
  address is ignored without any request. Provision is refused locally, and the server is re-read first, until funding is confirmed.
* **Stable operation keys.** `client_request_key` and the checkout `idempotency_key` are generated once, persisted, and reused on
  retry and relaunch. A lost create response is recovered by replaying the same key, or by adopting the intent found by name.
  Concurrent taps coalesce to one request. Funding cannot change once a checkout exists (the server would conflict on amount).
* **Durable before side effects.** Draft writes are never swallowed. Keys and form are saved before any account, create or
  checkout request; the intent id and checkout order are saved before checkout opens in the browser. A failed write surfaces as
  a persistence failure and stops further steps; relaunch replays the same keys, so no second payable order is made.
* **Signer binding.** Every request is signed through a per-controller wrapper that checks the expected key before signing and the
  pubkey of the signed event after, so an identity change mid-operation (create, checkout, cancel, provision) signs nothing.
* **Copy.** Unavailable/payment errors make no claim about money: a prior payment may exist, so they say progress is kept and to check status.
* **Revision conflicts.** `stale_revision` fetches the latest intent, adopts it, clears the review and shows the conflict.
* **Checkout validation.** The returned URL must be `https` on `stripe.com`; mode must be `test`; the amount must equal the intent.
* **Agents.** Only offers returned by the Tower can be chosen, with the cap within their maximum; an empty catalogue disables
  the section. A selected agent is reported as "chosen but not running"; the app sends no request for the user.
* **Landing.** The result screen claims General or an agent only if the intent's recorded steps or `agent_state` say so.

## Configuration

After verifying the NStack descriptor, the client reads authenticated `GET /api/v4/onboarding/config`. Card checkout requires
onboarding enabled, card available, test mode and a valid URL from the server's `HOSTING_STRIPE_RETURN_URLS` list. The server still
validates the exact URL on checkout. A disabled, live-mode or unsafe configuration cannot be overridden by a build setting.
Only an older deployment returning 404 uses the legacy `AmbulandoOnboardingReturnURL` Info.plist fallback. Plain `https`
(or loopback `http`) without credentials, query or fragment only; missing configuration leaves card unavailable.

## New identity, encrypted backup and the hosted copy (Mac build 124)

A device with no identity and no Tower connection can create one (Import screen > "Create a new identity"). The flow is the only way
the key is ever made, and the key reaches the vault last:

1. `IdentityService.beginNewIdentity` draws 32 bytes from `SecRandomCopyBytes` (redrawn until a valid secp256k1 scalar). The secret
   lives only in the identity actor's memory; the UI sees the npub.
2. The user picks a long, unique backup password (>= 16 chars); `NIP49` encrypts the key (`ncryptsec`, below). The user must **copy or save** it (explicit
   buttons; nothing is written automatically), then retype the password: the app decrypts the backup and requires the same key.
3. Only then `commitNewIdentity(pin:)` writes `identity-backup.json` (public record, no secret) and then the PIN vault. A record write or
   vault failure leaves the pending key in memory and creates nothing else; a vault failure removes the record again.
4. Payment stays gated. The wizard shows "Save your hosted backup": a username on the chosen NStack. `HostedBackupSaver` encrypts again
   (cost 16), decrypts it back, reads signed `GET /me` and **stages origin + username + exact ciphertext on disk before PUT** (CAS),
   then reads public `GET` and signed `GET /me`.
   It requires the public ciphertext and revision to equal the acknowledged write, then decrypts the read-back copy with the password and
   requires this identity's key, and only then records `hostedBackupConfirmedAt`. A lost response replays the identical staged body or adopts
   the row that landed; an existing copy is verified, never overwritten. Staging and confirmation atomically check the expected
   unlocked identity after asynchronous work. A confirmation on one origin does not unlock payment on another NStack.
5. `OnboardingController` checks `PaymentBackupGate` before any request (account, intent, options, checkout) and declares
   `identity_origin: "new"` on the intent, so the NStack refuses payment too (`409 identity_backup_required`, mapped to the same state).

Existing (imported) identities are untouched: no record, no gate, no `identity_origin`. "Import an encrypted backup" restores an `ncryptsec`
(pasted, or fetched from an NStack by username; only the ciphertext is downloaded). Settings > "Back up identity (encrypted)" exports on request.
A restored or imported key is not forced through the new-identity gate.

### NIP-49 implementation and its honest limits

`Crypto/NIP49.swift` follows the NIP exactly (NFKC password, scrypt r=8 p=1, XChaCha20-Poly1305, security byte as AD, 91-byte v2 payload,
bech32 `ncryptsec`). Primitives come from **CryptoSwift 1.9.0** (pinned exact; `Scrypt`, `AEADXChaCha20Poly1305`); nothing is hand-rolled.
swift-sodium 0.9.1 (the first choice) cannot do it: its `Clibsodium.xcframework` is a `SODIUM_LIBRARY_MINIMAL` build, `sodium.h` omits
`crypto_pwhash_scryptsalsa208sha256.h` and `nm libsodium.a` shows no scrypt symbol.

* Bounds are checked before any allocation: input <= 200 chars, payload 91 bytes, version 2, scrypt cost 10...18 on decrypt (<= 256 MiB),
  security byte 0...2, password 1...512 bytes, valid scalar. New and hosted backups use 16...18; the default is 16 (only a Mac was measured:
  logN 16 about 0.2 s, logN 18 about 0.75 s release; no iPhone figure exists, so 18 is not the default). One KDF runs at a time process-wide.
* scrypt and the AEAD run on a detached task, never the main actor.
* Wrong password, tampering of any byte and a wrong/unauthenticated security byte all fail with one error, with no partial result.
* Memory: the derived key, normalised password and working copies this code owns are overwritten before release; CryptoSwift copies its inputs and
  frees (does not zero) its scrypt scratch, and Swift `String`/`Data` may be copied by the runtime and the SwiftUI text fields. The wipe is best
  effort and is not claimed to be complete. Passwords, plaintext keys and backups are never logged.
* Tests (`NIP49Tests`): the official NIP-49 vector, nostr-tools 2.24.2 output on synthetic keys (incl. NFKC and each security byte), a
  deterministic known answer from noble (scrypt + xchacha20poly1305) with fixed salt/nonce, every-byte tamper, malformed/high-cost/huge input,
  invalid scalars, concurrent KDFs.

### Still not verified

No live NStack (the hosted-backup service was a committed contract, not a running service, when this was written), no real Stripe checkout, no
iPhone/iPad build or run, no device. The Mac Debug target builds. See the handoff for the dated list.

## Lightning and repeat top-ups (source; no live NStack, wallet or payment)

Contracts read from tower `src/routes/onboarding.ts`, `services/hosting-lightning.ts`, `services/hosting-topup.ts`, `docs/contract/funding-reversals-v1.md`,
`hosting-lightning-receiver-v1.md`, `onboarding-v1.md` (Tower HEAD `1250578`). Real receiving is disabled and unconfigured on NStack; nothing here was exercised
against a provider, mint, FX source or real payment.

| Call | Body (exact) | Result used |
| --- | --- | --- |
| `POST /intents/{id}/lightning/quote` | `{idempotency_key}` | `{quote}`: `id, intent_id, state, amount_cents, amount_sats, invoice, payment_hash, expires_at, rate{source,quoted_at}` |
| `POST /intents/{id}/lightning/quotes/{quoteId}/refresh` | `{}` | `{quote, intent}` (server re-polls its provider; the client supplies no evidence) |
| `GET /topups` | none | `{credited[], pending_lightning[], pending_checkout[]}` |
| `POST /topups/checkout` | `{idempotency_key, return_url, amount_cents}` | `{order_id, checkout_url, mode, amount_cents}` |
| `POST /topups/lightning/quote` | `{idempotency_key, amount_cents}` | `{quote}` with `intent_id: null` |
| `POST /topups/lightning/quotes/{quoteId}/refresh` | `{}` | `{quote}` |
| `GET /config` | none | `lightning.available`, `funding.topup_min_cents/topup_max_cents`, `card.*` (unchanged) |
| `GET /account` | none | `account`, `funding` (reversal debt / open adjustments), `lifecycle` |

**Intent Lightning** (`OnboardingController.continueToLightning`). Lightning is offered only when the signed config says `onboarding_enabled` and
`lightning.available`; an older NStack (no config) or a disabled one leaves it off and sends nothing. The USD amount is the intent's server-held figure;
the quote must be for this intent and equal that amount, or it is never shown. The invoice's own human-readable amount, when it names one, must equal the
quoted sats (`PayableInvoice`); the wallet verifies the checksum and signature. Screen: USD, sats, rate source and time, stated expiry, QR, copy and an
explicit "Open in wallet" (`lightning:` URL built from the shown invoice). Wallet return, "paid" in a wallet, the clock and the quote state alone never
fund; only the server intent (`funded && !funding_reversed`) does, learned from the refresh response or `GET /intents/{id}`.

* **One payment per setup.** `paymentMethod`, `lightningKey` and the quote id are saved before the request that can make an invoice. While a method is
  bound the other is refused locally (`paymentMethodLocked`) with nothing sent. A definite refusal made before any order (`lightning_unavailable`, 4xx) frees it;
  a lost or untrusted answer keeps the key and method, and the same key is replayed on retry and relaunch. A relaunch re-reads the quote through the refresh route.
  Funding cannot be edited once a card order or Lightning key exists.
* **Verified ends only.** `expired`/`cancelled` (provider-verified) release the key and method so a new invoice or card becomes possible. An unpaid mint quote stays
  `open` past its expiry (the receiver has no cancel): the screen says not to pay it and that NStack has not confirmed it closed, and never asks for a second invoice.
  `late_payment`, `mismatch` and unknown states show the quote reference for support, keep the lock and are never offered as payable. No refund payout exists on the receiver and none is invented.
* The hosted-backup gate, expected signer and `identity_origin: "new"` rules are shared with card; credit survives a failed provisioning step (no second invoice, no checkout).

**Top-ups** (`TopupController`, Settings > Connection > "Add credit to your account"). Server minimum US$21, presets 21 / 50 / 100, custom up to the
server's bound (from `config.funding.topup_*_cents` when published, else the documented US$21 to US$10,000). No fee, subscription, automatic top-up, workspace, seat or
introduction. The account summary (balance, reversal debt, lifecycle read-only days) is read from `GET /account`; nothing is converted or invented. Card needs
`card.available`, test mode and a server-approved `return_urls` entry from the same signed config; there is no build-time allowlist. The Stripe URL must be https on stripe.com,
mode `test` and the amount must equal the request before it opens. One attempt is open per (origin, signer): its key, amount and return address are saved before the request, replayed
unchanged after any failure or relaunch, and closed only by NStack's word (the order no longer listed, or a quote `settled`/`expired`/`cancelled`; late or mismatched
quotes are shown for support). Credit appears only as a listed settlement.

## Known gaps

See the handoff for the dated list. In short: the PIN vault is not an `ncryptsec` and is not a substitute for the backups above; Lightning
and top-ups are source-complete but not validated against a live NStack, agents and General are not provisioned by the backend yet, the return URL needs real configuration, no
invitation deep-link format exists in NStack, and nothing was exercised against a live Tower, a real Stripe test checkout or a device.
