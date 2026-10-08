---
name: shipit
description: "Ship it": write the requested feature, then open a PR, merge it, and deploy the service. Use when the user says /shipit, usually at the end of a feature request ("make the button 35% bigger, then /shipit").
---

Write the requested feature. When it's done, ship it:

1. Commit on a feature branch and open a PR with `gh pr create`.
2. Merge the PR with `gh pr merge` (this is explicitly authorized by `/shipit`; wait for required checks if the repo enforces them).
3. Deploy the service: switch the main checkout back to the default branch, pull, and run the project's `install.sh`.

If a step fails (tests, merge conflict, failing checks, install error), stop and report it — don't merge or deploy something broken. If the project has no `install.sh`, say so and don't guess at a deploy command.
