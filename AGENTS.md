# Working in this repository

## Branches: use lane

Every change happens in a [lane](https://lane.lukeed.com/usage/), never in the main checkout and never in a bare `git worktree add`.

1. `lane new <name>`, then work in the tree it prints (`.lane/trees/<name>`). lane clones ignored files by reflink, so `node_modules` and the native build scratch in `native/.build` come along without a reinstall or refetch.
2. `lane why <path>` before editing a file, and keep what its notes say still true.
3. Commit. Record a constraint another agent would otherwise rediscover with a `Why: <path> | <note>` trailer (see `.agents/skills/lane/SKILL.md`). Don't use trailers to summarize the change.
4. `lane check`, and confirm, replace or retire every stale note.
5. `lane push`, then `gh pr create`, and squash-merge the PR.
6. In the main checkout: `git pull --ff-only`, then `lane prune --dry-run`. Prune misses lanes whose PRs were squash-merged, so remove a merged lane with `lane rm <name>`.

`npm run dev-app` builds and launches the one dev copy of the app; see docs/build.md. Peekaboo is vendored: edit `native/vendor/Peekaboo` directly, and see `native/vendor/README.md`. Run its Swift tests only through `npm run peekaboo-test` with a narrow `--filter`, since they hold the real `~/.peekaboo` locks.
