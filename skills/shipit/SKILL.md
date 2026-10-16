---
name: shipit
description: "Ship it": write the requested feature, then open a PR, merge it, and deploy the service. Use when the user says /shipit, usually at the end of a feature request ("make the button 35% bigger, then /shipit").
---

Write the requested feature. When it's done, ship it:

1. Commit on a feature branch and open a PR with `gh pr create`.
2. Merge the PR with `gh pr merge` (this is explicitly authorized by `/shipit`; wait for required checks if the repo enforces them).
3. Deploy the service (except in T3 Code — see below): switch the main checkout back to the default branch, pull, and run the project's `install.sh`.

If a step fails (tests, merge conflict, failing checks, install error), stop and report it — don't merge or deploy something broken. If the project has no `install.sh`, say so and don't guess at a deploy command.

## T3 Code (DanielGGordon/t3code)

In the T3 Code repo (worktrees under `~/.t3/worktrees/t3code/`, deploy checkout `~/projects/meta/t3code-v2`), `/shipit` means: commit on a feature branch, open the PR, merge it with `gh pr merge --merge` (merge commit), and **STOP**. Do NOT run the `/redeploy` skill or `redeploy.sh`, and do NOT restart `t3code.service` or any T3 server. T3 has no `install.sh`; don't invent a deploy step.

Why: the agent session runs inside `t3code.service`, so a restart kills the session mid-task, and prod restarts need the user's separate explicit approval (`/redeploy`, or the test-deploy flow in `docs/test-deployments.md`).

Final report: say the PR is merged and prod was NOT redeployed, so the user can run `/redeploy` when ready.
