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
