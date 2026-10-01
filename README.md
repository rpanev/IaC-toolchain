# IaC toolchain

Installer and Makefile for Terraform / OpenTofu environments.

Copy `Makefile` into each environment directory and run `make` from there.
`ENV` is the directory name (`prod`, `dev`, …). There are no Terraform workspaces.

```text
environments/prod/     Makefile, *.tf, backend.hcl, terraform.tfvars
environments/dev/      Makefile, *.tf, ...
```

## Install

Linux (amd64 and arm64) and macOS. On Linux every download is checked with SHA256.
`checkov` goes into `/opt/checkov` and is linked into `/usr/local/bin`.

```bash
./install-iac-tools.sh
```

Terraform and OpenTofu are alternatives. If both are selected, the script asks which one to install. Without a terminal, pass the choice explicitly:

```bash
./install-iac-tools.sh --engine tofu
IAC_ENGINE=terraform ./install-iac-tools.sh
```

| Command | What it does |
|---|---|
| `./install-iac-tools.sh` | Install anything that is missing |
| `--only trivy,checkov` | Only these tools |
| `--skip infracost` | Skip a tool |
| `--engine terraform\|tofu` | Pick the engine, no prompt |
| `--check` | Show outdated tools, change nothing (exit 2 if updates exist) |
| `--update` | Upgrade outdated tools and install missing ones |
| `--force` | Reinstall the selected tools |
| `--dry-run` | Print actions only |

Pin a version with `<TOOL>_VERSION` (`terraform-docs` → `TERRAFORM_DOCS_VERSION`):

```bash
TRIVY_VERSION=0.58.1 TERRAFORM_VERSION=1.9.8 ./install-iac-tools.sh
```

Other variables: `INSTALL_DIR` (default `/usr/local/bin`), `CHECKOV_VENV` (default `/opt/checkov`).

Tools: `terraform`, `tofu`, `tflint`, `terraform-docs`, `trivy`, `checkov`, `conftest`, `gitleaks`, `infracost`.
Also installed when missing: GNU make (>= 3.82), `curl`, `unzip`, `tar`, `git`.

`infracost` v2 needs a login before `make cost`:

```bash
infracost auth login
# no browser: infracost auth login --oauth-use-device-flow
# CI: export INFRACOST_CLI_AUTHENTICATION_TOKEN=...
```

## Use the Makefile

The file must be named `Makefile`. `make` does not load `Makefiles`.

```bash
cp /root/iac/Makefile environments/prod/Makefile
cd environments/prod
make help
```

Engine selection, first match wins:

1. `TF=terraform` or `TF=tofu` on the command line
2. a `*.tofu` or `.opentofu-version` file in the directory → OpenTofu
3. `terraform` if it is on `PATH`
4. `tofu` if it is on `PATH`

If both binaries are installed, the Makefile uses Terraform unless you pass `TF=tofu`.

```bash
make init
make plan
make apply-plan
make ci-checks CI=true
make plan PLAN_ARGS=-destroy && make apply-plan
```

`prod` and `production` are protected (`PROTECTED_ENVS`). `make apply` and `make destroy` are refused there. The only apply path is `make plan`, then `make apply-plan`.

`make destroy` is also refused when `CI=true`. Otherwise it asks you to type the environment name.

### Targets

| Target | |
|---|---|
| `help` / `version` | Usage, and versions of the installed tools |
| `init` / `upgrade` / `lock` | Init, upgrade providers, lock linux + darwin platforms |
| `plan` | Write `tfplan.binary` and `tfplan.json` |
| `apply-plan` | Apply the saved plan |
| `apply` / `destroy` | Interactive. Blocked for protected environments |
| `drift` | Plan with `-detailed-exitcode` (exit 2 = drift) |
| `output` / `state-list` | Outputs and state |
| `fmt` / `fmt-check` / `validate` / `test` | Format, check, validate, `*.tftest.hcl` |
| `docs` / `docs-check` | `terraform-docs` README in the environment directory |
| `lint` | tflint |
| `trivy` / `checkov` / `checkov-plan` / `policy` / `secrets` | Scanners |
| `cost` | Infracost report → `cost.md` |
| `security` | All security scans, reports in `security-report/` |
| `scan` | trivy + checkov + secrets |
| `checks` | fmt, validate, docs, lint, scan |
| `ci-checks` | Same, read-only (`fmt-check`, `docs-check`) |
| `plan-checks` | plan + checkov-plan + conftest |
| `clean` | Remove `.terraform`, plans, and reports. Keeps `.terraform.lock.hcl` |

`make docs` overwrites `README.md` in the environment directory. It does not touch this file.

### Variables

Set them on the command line or in `.env.mk` in the environment directory.

| Variable | Default | |
|---|---|---|
| `TF` | see above | `terraform` or `tofu` |
| `CI` | `false` | `true` enables CI report formats and `SECURITY_FAIL` |
| `VAR_FILE` | | Extra `-var-file` (`terraform.tfvars` is loaded by Terraform itself) |
| `BACKEND_CONFIG` | `backend.hcl` | Passed to `init` when the file exists |
| `PLAN_ARGS` / `INIT_ARGS` | | Extra arguments |
| `EXPECTED_ACCOUNT_ID` | | `plan` / `apply` check `aws sts get-caller-identity` |
| `PROTECTED_ENVS` | `prod production` | Names that cannot `apply` or `destroy` directly |
| `SECURITY_VERBOSE` | `0` | `1` prints full scanner output |
| `SECURITY_FAIL` | `0` | `1` makes `make security` exit non-zero on findings |
| `TRIVY_SEVERITY` | `MEDIUM,HIGH,CRITICAL` | |

Configs are searched in the environment directory, then parents, up to the git root: `.checkov.yaml`, `.tflint.hcl`, `.gitleaks.toml`, `policy/`.

Add to `.gitignore` in the Terraform repo:

```gitignore
tfplan*
reports/
security-report/
cost.md
```
