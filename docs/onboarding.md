# Invited onboarding (Mac source build 120, first slice)

A signed-in user can start a new NStack workspace from a capped group invitation: choose a workspace name, optionally an
agent from the Tower's versioned catalogue, a funding amount (US$21 / 50 / 100 or a custom amount of at least US$21),
review, pay in Stripe **test mode**, and have the Tower create the workspace. Existing manual connections are untouched.

This slice is **workspace-only and test-mode**. See "Known gaps" before treating it as launch-ready.

## Contract used

NStack `/api/v4/onboarding` (tower `docs/contract/onboarding-v1.md`, `src/routes/onboarding.ts`, `src/services/onboarding.ts`),
human direct-signature NIP-98 only. Native uses: `GET/POST /account`, `GET /agent-offers`, `GET/POST /intents`,
`GET /intents/{id}`, `POST /intents/{id}/options|cancel|checkout|provision`. It does **not** call `GET /invites/{code}`
(the code would sit in a URL path), the Lightning routes (no provider exists) or any `/admin` route.

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

`AmbulandoOnboardingReturnURL` (Info.plist string) is the address Stripe returns to. The server accepts only an exact member of
its `HOSTING_STRIPE_RETURN_URLS`, and no endpoint exposes that list, so it is build configuration. **Unset means card checkout is
switched off** ("no approved payment return address"). Plain `https` (or loopback `http`) without credentials, query or fragment only.

## Known gaps

See the handoff for the dated list. In short: no new-identity creation (a NIP-49 `ncryptsec` implementation with scrypt and
XChaCha20-Poly1305 and the hosted-username ciphertext service do not exist; the PIN vault is not an `ncryptsec` and is not a substitute; full `ncryptsec` waits on the backend contract), Lightning
is shown unavailable, agents and General are not provisioned by the backend yet, the return URL needs real configuration, no
invitation deep-link format exists in NStack, and nothing was exercised against a live Tower, a real Stripe test checkout or a device.
