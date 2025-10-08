# Remote Repository Configuration

This repository snapshot is not connected to any remote. To publish your local
commits to GitHub, configure the remote and push the current branch. The latest
shared baseline lives on commit `56aafae2`, so point your remote at that ref
instead of the older `5d73058e` revision when you synchronise:

```bash
git remote add origin git@github.com:billlza/Skybridge-Compass.git
git fetch origin 56aafae2
git checkout 56aafae2 -b work
git push -u origin work
```

If you need the changes on `main`, update your local branch or create a pull
request on GitHub:

```bash
git checkout main
git merge work
git push origin main
```

> Note: The QA environment that produced these commits cannot reach external
> networks, so the remote must be configured and pushes performed from your own
> machine. Always confirm `git rev-parse HEAD` equals `56aafae2` before opening
> a pull request so the history matches the remote branch expectations.
