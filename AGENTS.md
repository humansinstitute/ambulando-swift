# Ambulando Native Agent Instructions

## Mac testing and delivery

Pete deploys Ambulando Native to his local MacBook by pulling GitHub `main`
and building locally. When changes to Mac Native need testing, validate them,
commit them to `main`, and push `main` to the GitHub `origin` remote
(`humansinstitute/ambulando-swift`) before handing them back for testing.
Local commits or locally built app bundles alone do not deliver the changes.

Verify that GitHub `refs/heads/main` contains the delivered commit after the
push. Report the Mac build number and distinguish pushed source from an app
actually installed and tested on Pete's MacBook. Do not claim installation or
live verification without evidence.

Preserve concurrent work and existing remotes. Never force-push, rewrite
history, or discard unfamiliar changes to complete delivery. If a normal push
is blocked, report the blocker explicitly rather than claiming completion.

<!-- post-work-cleanup:v1 -->
## Build, simulator and test cleanup

Before declaring build/test work complete, remove the disposable outputs created by the task: temporary build trees, test results, simulator clones, emulator snapshots and scratch downloads. Shut down task-owned test devices and processes when finished. Preserve source, signing material, release deliverables, required evidence, installed user data and anything used by concurrent work. Check ownership and active processes before deleting shared caches or devices; use supported simulator/emulator tooling. Measure disk space before and after cleanup and report what was reclaimed, what remains and why. Cleanup is part of completion; workers must include it in their handoff. Retain large caches or test environments only with an explicit reason and a cleanup owner/time.
<!-- /post-work-cleanup:v1 -->

## NStack contract boundary

NStack is intended as a pluggable backend for independent apps. Use verified existing contracts for current Ambulando data, permissions, revisions and sync; preserve record identities and installed-client compatibility. Before proposing a NStack endpoint, table, server type enum or shared-contract change for a native feature, read the installed `wingman-be-free-platform` skill and `references/pluggable-app-boundary.md`. Keep application formats and business rules in Ambulando; identify a missing reusable platform capability instead of assuming a bespoke NStack endpoint is required. App-signed database access does not imply end-user row permissions, and source presence does not establish live availability.
