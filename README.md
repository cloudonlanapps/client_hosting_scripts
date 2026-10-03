# client_hosting_scripts

Builds a brand's Flutter web frontends — an app and, optionally, a website —
from a **core repository's templates**, and publishes them to a VPS behind
nginx. Generic: every name, URL and ref arrives as a parameter or from the
caller's conf. It knows no product, no repository and no branch.

The server-side counterpart is
[server_hosting_scripts](https://github.com/cloudonlanapps/server_hosting_scripts);
the two share nothing.

## The two things a caller supplies

**A core repository** with a generator: a Dart package whose `bin/generate.dart`
takes `--target app|website --brand <dir> --out <dir> --api-url <url>
[--app-url <url>] [--website-url <url>]` and creates a Flutter project that
`flutter build web` builds. The core is cloned at a branch per environment, so
each environment's build comes from the core that matches its API.

**A brand folder**: whatever files the generator reads, plus a conf. If the
folder has a `website/` subfolder, a website is built too.

## Usage

```bash
web/deploy_web-conf.sh <brand>/brand.conf <env> <run|build|publish|release>
```

| action | does |
|---|---|
| `build` | clones the core at `<env>_CORE_REF`, generates the app (and website), runs `flutter build web`, and writes `out/` |
| `run` | builds, then serves the app and website on localhost, with unknown paths falling back to `index.html` as nginx does |
| `publish` | rsyncs the last build to `/var/www/<host>` on the VPS, and nginx files and the README to `~/web_deploy/<brand>-<env>/` |
| `release` | build, then publish |

`deploy_web-conf.sh` reads the conf and calls `web/deploy_web.sh`, which takes
everything as flags (`--help` lists them) for callers without a conf.

## The conf

Sourced as bash; it lives in the brand folder.

```bash
ENVS=(dev beta prod)

CORE_URL="git@github.com:example/core.git"
GENERATOR="project_generator"          # the generator's folder inside the core

SSH_USER="deploy"                      # the VPS publish rsyncs to
SSH_HOST="203.0.113.10"
SSH_PORT="22"

prod_CORE_REF="release"
prod_API_URL="https://api.example.org/v1"
prod_APP_URL="https://app.example.org"
prod_WEBSITE_URL="https://example.org"           # required with website/, refused without
prod_WEBSITE_ALIASES="www.example.org"           # optional: more hosts for the website

beta_CORE_REF="beta_release"
beta_API_URL="https://beta-api.example.org/v1"
beta_APP_URL="https://beta-app.example.org"
beta_WEBSITE_URL="https://beta.example.org"

dev_CORE_REF="main"
dev_API_URL="http://192.168.0.10:8000/v1"        # dev needs only the API
```

- Every URL is used whole: an IP or any domain, with or without a subdomain.
  Nothing derives one from another.
- nginx's server names and the web roots (`/var/www/<host>`) are the hosts of
  those URLs.
- A brand without a website may list `<env>_REDIRECT_HOSTS`: hosts redirecting
  to the app.
- **`dev`** is built for the local machine: served on `localhost:8080` (app)
  and `:8081` (website) (`DEV_APP_PORT`, `DEV_WEBSITE_PORT`), no nginx or
  README, never published. The dev API must accept those origins.

## Output

In `WORK_DIR` (default: `<env>/` beside this tooling checkout):

```
core/           the core, at <env>_CORE_REF
app/ website/   the generated projects
out/
  app/          the built app
  website/      the built website, when the brand has one
  nginx/        port-80 vhosts: app, website or redirect (not dev)
  README.md     DNS, web roots, nginx and certbot steps for this env (not dev)
  build.info    core ref and commit, this tooling's commit, Flutter version, API, hosts
```

`main.dart.js` and `flutter_bootstrap.js` are renamed to carry the build time,
so a browser never pairs a new `index.html` with an old script, and the service
worker is dropped. The vhosts are self-contained and listen on port 80 only;
`certbot --nginx` adds HTTPS. `index.html` is never cached, the two timestamped
scripts are cached for good, everything else is revalidated.

**publish** refuses an output with no `build.info` (a build that failed part
way), a dev build, or one built for other hosts than the conf now names.

## Requirements

`git`, `flutter` (with `dart`), `rsync`, and `python3` for `run`, on the build
machine; SSH access to the core repository and, for publishing, to the VPS.
Builds never run on the VPS.
