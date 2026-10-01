# =============================================================================
# Makefile for Terraform / OpenTofu
#
# Layout: one directory per environment (no workspaces), e.g.
#   environments/demo/  environments/prod/  ...
# ENV = name of the current directory. Run make from inside it.
#
# Usage:  make <target> [TF=terraform|tofu] [CI=true]
#
#   cd environments/demo && make init && make plan && make apply-plan
#   make ci-checks CI=true
#   make plan PLAN_ARGS=-destroy && make apply-plan
#
# Requires bash (Alpine images: apk add --no-cache bash make).
# Add to .gitignore: tfplan*  reports/  security-report/  (cost.md - optional)
# =============================================================================

# ---------------------------------------------------------- Main switches ---
# 1 = show full tool output during 'make security' (0 = summary only)
SECURITY_VERBOSE    ?= 0
# 1 = 'make security' exits non-zero when something fails (CI=true forces 1)
SECURITY_FAIL       ?= 0
# Per-tool reports, overwritten on every run
SECURITY_REPORT_DIR ?= security-report
# Infracost markdown report ('make cost'), overwritten on every run
COST_REPORT         ?= cost.md

SHELL         := /bin/bash
.SHELLFLAGS   := -euo pipefail -c
MAKEFLAGS     += --no-builtin-rules --no-print-directory
.DEFAULT_GOAL := help
.DELETE_ON_ERROR:
.NOTPARALLEL:

# ----------------------------------------------------------------- Config ---
ENV ?= $(notdir $(CURDIR))

# Optional local overrides in the env dir (EXPECTED_ACCOUNT_ID, VAR_FILE, ...)
-include .env.mk

# Binary: TF=... wins; else *.tofu / .opentofu-version -> tofu;
# else terraform if installed; else tofu
ifeq ($(origin TF),undefined)
  ifneq ($(wildcard *.tofu .opentofu-version),)
    TF := tofu
  else ifneq ($(shell command -v terraform 2>/dev/null),)
    TF := terraform
  else ifneq ($(shell command -v tofu 2>/dev/null),)
    TF := tofu
  else
    TF := terraform
  endif
endif

PROTECTED_ENVS      ?= prod production
CI                  ?= false
EXPECTED_ACCOUNT_ID ?=

# terraform.tfvars / *.auto.tfvars are auto-loaded by terraform/tofu.
# Extra var-file is optional: make plan VAR_FILE=extra.tfvars
VAR_FILE       ?=
BACKEND_CONFIG ?= backend.hcl
INIT_ARGS      ?=
PLAN_ARGS      ?=

PLAN        ?= tfplan.binary
PLAN_JSON   := $(PLAN:.binary=.json)
REPORTS_DIR ?= reports

# Configs are searched upward: env dir -> parents -> git root
GIT_ROOT   := $(shell git rev-parse --show-toplevel 2>/dev/null)
find_up     = $(firstword $(foreach d,. .. ../.. ../../.. $(GIT_ROOT),$(wildcard $(d)/$(1))))

CHECKOV_CONFIG ?= $(call find_up,.checkov.yaml)
TFLINT_CONFIG  ?= $(call find_up,.tflint.hcl)
POLICY_DIR     ?= $(call find_up,policy)
TRIVY_SEVERITY ?= MEDIUM,HIGH,CRITICAL
GITLEAKS_ARGS  ?= --no-git
GITLEAKS_CONFIG ?= $(call find_up,.gitleaks.toml)
SECURITY_SCANS ?= trivy checkov secrets
LOCK_PLATFORMS ?= linux_amd64 linux_arm64 darwin_amd64 darwin_arm64

# ---------------------------------------------------------------- Derived ---
TF_INPUT     := -input=false
TF_LOCK      := -lock-timeout=5m
VAR_ARGS     := $(if $(VAR_FILE),-var-file=$(VAR_FILE))
# File passed to scanners (trivy/checkov): VAR_FILE if given, else terraform.tfvars
SCAN_VARS    := $(or $(VAR_FILE),$(wildcard terraform.tfvars))
VARS_DESC    := $(or $(strip $(wildcard terraform.tfvars *.auto.tfvars) $(VAR_FILE)),no tfvars)
BACKEND_ARGS := $(if $(wildcard $(BACKEND_CONFIG)),-backend-config=$(BACKEND_CONFIG))
CHECKOV_ARGS := $(if $(CHECKOV_CONFIG),--config-file $(CHECKOV_CONFIG)) \
                --skip-path $(SECURITY_REPORT_DIR) --skip-path $(REPORTS_DIR)
SUBMAKE      := NO_COLOR=1 ANSI_COLORS_DISABLED=1 $(MAKE) -s -f $(firstword $(MAKEFILE_LIST))
TFLINT_ARGS  := $(if $(TFLINT_CONFIG),--config=$(abspath $(TFLINT_CONFIG)))
IS_PROTECTED := $(filter $(ENV),$(PROTECTED_ENVS))

ifeq ($(CI),true)
SECURITY_FAIL := 1
export TF_IN_AUTOMATION := 1
export NO_COLOR := 1
endif

ifdef NO_COLOR
GREEN  :=
YELLOW :=
RED    :=
BOLD   :=
RESET  :=
else
GREEN  := $(shell tput setaf 2 2>/dev/null)
YELLOW := $(shell tput setaf 3 2>/dev/null)
RED    := $(shell tput setaf 1 2>/dev/null)
BOLD   := $(shell tput bold 2>/dev/null)
RESET  := $(shell tput sgr0 2>/dev/null)
endif

# Default gitleaks config (used when no .gitleaks.toml is found):
# built-in rules + ignore local terraform artifacts (plan files hold secrets
# in clear text by design and are never committed)
define GITLEAKS_DEFAULT_CONFIG
[extend]
useDefault = true

[allowlist]
description = "Local Terraform/OpenTofu artifacts"
paths = [
  '''(^|/)\.terraform/''',
  '''(^|/)tfplan[^/]*$$''',
  '''(^|/)terraform\.tfstate(\.backup)?$$''',
  '''(^|/)security-report/''',
  '''(^|/)reports/''',
]
endef
export GITLEAKS_DEFAULT_CONFIG

# Messages passed to these must not contain commas
log  = printf '%s+ %s%s\n' "$(GREEN)" "$(1)" "$(RESET)"
warn = printf '%s! %s%s\n' "$(YELLOW)" "$(1)" "$(RESET)"
die  = { printf '%s✗ %s%s\n' "$(RED)" "$(1)" "$(RESET)" >&2; exit 1; }

.PHONY: help version init upgrade lock plan apply-plan apply destroy \
        drift output state-list fmt fmt-check validate test docs docs-check lint \
        trivy checkov checkov-plan policy secrets cost security scan checks ci-checks \
        plan-checks clean gitlog \
        .need-init .need-plan .check-account .check-protected

##@ Help
help: ## Show this help
        @awk 'BEGIN {FS = ":.*##"; printf "\nUsage: make $(BOLD)<target>$(RESET) [TF=terraform|tofu] [CI=true]\n"} \
        /^[a-zA-Z0-9_-]+:.*##/ { printf "  $(GREEN)%-14s$(RESET) %s\n", $$1, $$2 } \
        /^##@/ { printf "\n$(BOLD)%s$(RESET)\n", substr($$0, 5) }' $(MAKEFILE_LIST)
        @printf '\nCurrent: ENV=%s TF=%s CI=%s\n\n' "$(ENV)" "$(TF)" "$(CI)"

version: ## Show versions of installed tools
        @for t in terraform tofu tflint terraform-docs trivy checkov conftest gitleaks infracost; do \
                if command -v $$t >/dev/null 2>&1; then \
                        printf '  %-16s %s\n' "$$t" "$$($$t --version 2>&1 | head -n1)"; \
                else \
                        printf '  %-16s %s\n' "$$t" "$(YELLOW)not installed$(RESET)"; \
                fi; \
        done

##@ Terraform lifecycle
init: .need-$(TF) ## Initialize backend (ENV-aware backend config)
        @$(call log,Initializing $(TF) [$(or $(BACKEND_ARGS),default backend)])
        @$(TF) init $(TF_INPUT) $(BACKEND_ARGS) $(INIT_ARGS)

upgrade: .need-$(TF) ## Upgrade providers/modules and refresh lock file
        @$(call log,Upgrading providers)
        @$(TF) init $(TF_INPUT) -upgrade $(BACKEND_ARGS) $(INIT_ARGS)
        @$(MAKE) lock

lock: .need-$(TF) .need-init ## Lock providers for linux + darwin platforms
        @$(call log,Locking providers for: $(LOCK_PLATFORMS))
        @$(TF) providers lock $(addprefix -platform=,$(LOCK_PLATFORMS))

plan: .need-$(TF) .need-init .check-account ## Create plan + JSON for scanners
        @$(if $(VAR_FILE),test -f $(VAR_FILE) || $(call die,VAR_FILE=$(VAR_FILE) not found),true)
        @$(call log,Planning ENV=$(ENV) [$(VARS_DESC)])
        @$(TF) plan $(TF_INPUT) $(TF_LOCK) $(VAR_ARGS) $(PLAN_ARGS) -out=$(PLAN)
        @$(TF) show -json $(PLAN) > $(PLAN_JSON)
        @$(call log,Saved $(PLAN) and $(PLAN_JSON))

apply-plan: .need-$(TF) .need-init .need-plan .check-account ## Apply saved plan (only path for protected ENVs)
        @$(call log,Applying $(PLAN))
        @$(TF) apply $(TF_INPUT) $(TF_LOCK) $(PLAN)
        @rm -f $(PLAN) $(PLAN_JSON)

apply: .check-protected .need-$(TF) .need-init .check-account ## Interactive apply (blocked for protected ENVs)
        @$(call log,Applying ENV=$(ENV))
        @$(TF) apply $(TF_LOCK) $(VAR_ARGS)

destroy: .check-protected .need-$(TF) .need-init .check-account ## Destroy resources (blocked for protected ENVs and CI)
        @[ "$(CI)" != "true" ] || $(call die,destroy is not allowed from CI)
        @read -r -p "$(RED)Destroy ENV=$(ENV)? Type '$(ENV)' to confirm: $(RESET)" ans; \
                [ "$$ans" = "$(ENV)" ] || $(call die,Aborted)
        @$(TF) destroy $(TF_LOCK) $(VAR_ARGS) -auto-approve

drift: .need-$(TF) .need-init ## Detect drift (exit 2 = drift found)
        @rc=0; $(TF) plan $(TF_INPUT) -lock=false -detailed-exitcode $(VAR_ARGS) || rc=$$?; \
        case $$rc in \
                0) $(call log,No drift in ENV=$(ENV)) ;; \
                2) $(call warn,DRIFT DETECTED in ENV=$(ENV)); exit 2 ;; \
                *) exit $$rc ;; \
        esac

output: .need-init ## Show Terraform outputs
        @$(TF) output

state-list: .need-init ## List resources in state
        @$(TF) state list

##@ Code quality
fmt: .need-$(TF) ## Format code recursively
        @$(TF) fmt -recursive

fmt-check: .need-$(TF) ## Check formatting without changes (CI)
        @$(call log,Checking formatting)
        @$(TF) fmt -check -recursive -diff

validate: .need-$(TF) ## Validate config (backend-less init - CI safe)
        @$(call log,Validating configuration)
        @$(TF) init $(TF_INPUT) -backend=false >/dev/null
        @$(TF) validate

test: .need-$(TF) .need-init ## Run native tests (*.tftest.hcl)
        @$(call log,Running $(TF) test)
        @$(TF) test $(VAR_ARGS)

docs: .need-terraform-docs ## Generate README.md via terraform-docs
        @$(call log,Generating docs)
        @terraform-docs markdown table --output-file README.md . >/dev/null

docs-check: .need-terraform-docs ## Fail if README.md is outdated (CI)
        @$(call log,Checking docs are up to date)
        @terraform-docs markdown table --output-file README.md --output-check .

lint: .need-tflint | $(REPORTS_DIR) ## Run tflint (JUnit report in CI)
        @$(call log,Running tflint)
        @tflint --init $(TFLINT_ARGS) >/dev/null
ifeq ($(CI),true)
        @tflint $(TFLINT_ARGS) --format=junit > $(REPORTS_DIR)/tflint.xml || \
                { tflint $(TFLINT_ARGS) --format=compact; exit 1; }
else
        @tflint $(TFLINT_ARGS)
endif

##@ Security
trivy: .need-trivy | $(REPORTS_DIR) ## Trivy IaC misconfiguration scan (SARIF in CI)
        @$(call log,Running Trivy [$(TRIVY_SEVERITY)])
ifeq ($(CI),true)
        @trivy config --quiet --severity $(TRIVY_SEVERITY) $(if $(SCAN_VARS),--tf-vars $(SCAN_VARS)) \
                --format sarif --output $(REPORTS_DIR)/trivy.sarif --exit-code 0 .
endif
        @trivy config --quiet --severity $(TRIVY_SEVERITY) $(if $(SCAN_VARS),--tf-vars $(SCAN_VARS)) --exit-code 1 .

checkov: .need-checkov | $(REPORTS_DIR) ## Checkov static scan of .tf (JUnit in CI)
        @$(call log,Running Checkov)
ifeq ($(CI),true)
        @checkov -d . $(CHECKOV_ARGS) $(if $(SCAN_VARS),--var-file $(SCAN_VARS)) --quiet --compact \
                -o cli -o junitxml --output-file-path console,$(REPORTS_DIR)
else
        @checkov -d . $(CHECKOV_ARGS) $(if $(SCAN_VARS),--var-file $(SCAN_VARS)) --quiet --compact
endif

# Note: if .checkov.yaml sets 'directory' or 'framework' it may conflict here
checkov-plan: .need-checkov .need-plan ## Checkov scan of plan JSON (resolved values)
        @$(call log,Running Checkov on $(PLAN_JSON))
        @checkov -f $(PLAN_JSON) --framework terraform_plan --repo-root-for-plan-enrichment . \
                $(CHECKOV_ARGS) --quiet --compact

policy: .need-plan ## OPA/Conftest policies against plan JSON
        @if [ -z "$(POLICY_DIR)" ]; then $(call warn,No policy/ dir found (searched up to git root) - skipping); exit 0; fi; \
                command -v conftest >/dev/null 2>&1 || $(call die,conftest is not installed); \
                $(call log,Running Conftest); \
                conftest test $(PLAN_JSON) --policy $(POLICY_DIR) --all-namespaces

secrets: .need-gitleaks ## Scan for hardcoded secrets (gitleaks)
        @$(call log,Running gitleaks$(if $(GITLEAKS_CONFIG), [$(GITLEAKS_CONFIG)]))
        @cfg="$(GITLEAKS_CONFIG)"; \
        if [ -z "$$cfg" ]; then \
                cfg="$$(mktemp)"; trap 'rm -f "$$cfg"' EXIT; \
                printf '%s\n' "$$GITLEAKS_DEFAULT_CONFIG" > "$$cfg"; \
        fi; \
        gitleaks detect --source . --no-banner --redact --verbose --config "$$cfg" $(GITLEAKS_ARGS)

cost: .need-infracost ## Cost estimate -> cost.md (infracost v2 scan / legacy v0.x breakdown)
        @v="$$(infracost --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sed -n 1p)"; \
        out="$$(mktemp)"; trap 'rm -f "$$out"' EXIT; \
        $(call log,Running infracost $$v); \
        set +e; \
        if [ "$${v%%.*}" -ge 2 ] 2>/dev/null; then \
                NO_COLOR=1 infracost scan . > "$$out" 2>&1; st=$$?; \
                hint="Not logged in? Run: infracost auth login (CI: INFRACOST_CLI_AUTHENTICATION_TOKEN)"; \
        else \
                if [ ! -f "$(PLAN_JSON)" ]; then echo "$(PLAN_JSON) not found - run: make plan" > "$$out"; st=1; \
                else NO_COLOR=1 INFRACOST_SKIP_UPDATE_CHECK=true infracost breakdown --no-color --path $(PLAN_JSON) > "$$out" 2>&1; st=$$?; fi; \
                hint="Legacy infracost $$v - upgrade: ./install-iac-tools.sh --update --only infracost"; \
        fi; \
        set -e; \
        sed -i.bak $$'s/\x1b\\[[0-9;]*[a-zA-Z]//g' "$$out" && rm -f "$$out.bak"; \
        if [ "$$st" -ne 0 ]; then cat "$$out" >&2; $(call die,$$hint); fi; \
        total="$$(grep -iE 'total.*\$$[0-9]' "$$out" | sed -n 1p | grep -oE '\$$[0-9][0-9,]*(\.[0-9]+)?' | tail -n1 || true)"; \
        { \
                echo "# Infracost cost estimate - $(ENV)"; \
                echo; \
                echo "| | |"; \
                echo "|---|---|"; \
                echo "| Environment | \`$(ENV)\` |"; \
                echo "| Directory | \`$(CURDIR)\` |"; \
                echo "| Generated | $$(date '+%Y-%m-%d %H:%M:%S') |"; \
                echo "| Infracost | $$v |"; \
                echo "| Total monthly | **$${total:-n/a}** |"; \
                echo; \
                echo "## Breakdown"; \
                echo; \
                echo '```text'; \
                cat "$$out"; \
                echo '```'; \
        } > "$(COST_REPORT)"; \
        $(call log,Total monthly: $${total:-n/a}  ->  $(COST_REPORT))

security: ## Run ALL security scans - per-tool reports in security-report/ + summary
        @rc=0; sum=""; csum=""; dir="$(SECURITY_REPORT_DIR)"; scans="$(SECURITY_SCANS)"; \
        noise='^make\[[0-9]*\]: \*\*\*'; \
        mkdir -p "$$dir"; rm -f "$$dir"/*.txt; \
        if [ -f "$(PLAN)" ] && [ -f "$(PLAN_JSON)" ]; then scans="$$scans checkov-plan policy"; \
        else \
                printf -v line '  %s %-5s %-13s %s' - SKIP "plan scans" "no $(PLAN) - run: make plan"; \
                sum="$$sum$$line\n"; csum="$$csum$(YELLOW)$$line$(RESET)\n"; \
        fi; \
        for s in $$scans; do \
                case $$s in \
                        secrets)      bin=gitleaks; name=gitleaks ;; \
                        checkov-plan) bin=checkov;  name=checkov-plan ;; \
                        policy)       bin=conftest; name=conftest ;; \
                        *)            bin=$$s;      name=$$s ;; \
                esac; \
                f="$$dir/$$name.txt"; skip=""; \
                if [ "$$s" = policy ] && [ -z "$(POLICY_DIR)" ]; then skip="no policy/ dir"; \
                elif ! command -v $$bin >/dev/null 2>&1; then skip="$$bin not installed"; fi; \
                if [ -n "$$skip" ]; then \
                        printf -v line '  %s %-5s %-13s %s' - SKIP "$$name" "$$skip"; \
                        sum="$$sum$$line\n"; csum="$$csum$(YELLOW)$$line$(RESET)\n"; continue; \
                fi; \
                [ "$(SECURITY_VERBOSE)" != 1 ] || printf '\n$(BOLD)==== %s ====$(RESET)\n' "$$name"; \
                set +e; \
                if [ "$(SECURITY_VERBOSE)" = 1 ]; then \
                        $(SUBMAKE) $$s 2>&1 | grep -v "$$noise" | tee "$$f"; st=$${PIPESTATUS[0]}; \
                else \
                        $(SUBMAKE) $$s 2>&1 | grep -v "$$noise" > "$$f"; st=$${PIPESTATUS[0]}; \
                fi; \
                set -e; \
                case $$s in \
                        trivy)                n=$$(awk '/^Failures: /{n+=$$2} END{print n+0}' "$$f") ;; \
                        checkov|checkov-plan) n=$$(awk -F'Failed checks: ' 'NF>1{split($$2,a,",");n+=a[1]} END{print n+0}' "$$f") ;; \
                        secrets)              n=$$(awk -F'leaks found: ' 'NF>1{n=$$2+0} END{print n+0}' "$$f") ;; \
                        policy)               n=$$(awk '{for(i=2;i<=NF;i++) if($$i ~ /^failures?,?$$/) n+=$$(i-1)} END{print n+0}' "$$f") ;; \
                        *)                    n=0 ;; \
                esac; \
                if [ "$$st" -eq 0 ]; then \
                        sym="✓"; mark=PASS; col="$(GREEN)"; detail="clean"; \
                        [ "$$n" -eq 0 ] || detail="$$n findings"; \
                elif [ "$$n" -gt 0 ]; then \
                        sym="✗"; mark=FAIL; col="$(RED)"; detail="$$n findings"; rc=1; \
                else \
                        sym="✗"; mark=ERROR; col="$(RED)"; detail="tool error - see report"; rc=1; \
                fi; \
                printf -v line '  %s %-5s %-13s %-24s %s' "$$sym" "$$mark" "$$name" "$$detail" "$$f"; \
                sum="$$sum$$line\n"; csum="$$csum$$col$$line$(RESET)\n"; \
        done; \
        hdr="==== Security summary (ENV=$(ENV)) ===="; \
        printf '\n$(BOLD)%s$(RESET)\n%b' "$$hdr" "$$csum"; \
        printf '%s\n%s\n\n%b' "$$hdr" "$$(date '+%Y-%m-%d %H:%M:%S')" "$$sum" > "$$dir/summary.txt"; \
        printf '\nReports: %s/   (SECURITY_VERBOSE=1 to show tool output)\n\n' "$$dir"; \
        if [ "$$rc" -ne 0 ] && [ "$(SECURITY_FAIL)" = 1 ]; then exit 1; fi

##@ Aggregates
scan: trivy checkov secrets ## All static security scans

checks: fmt validate docs lint scan ## Local: auto-fix fmt/docs + lint + scans
        @$(call log,All checks passed)

ci-checks: fmt-check validate docs-check lint scan ## CI: read-only checks + reports
        @$(call log,All CI checks passed)

plan-checks: plan checkov-plan policy ## Plan + plan-level scans (Checkov + Conftest)
        @$(call log,Plan checks passed)

##@ Misc
clean: ## Remove local artifacts (keeps .terraform.lock.hcl)
        @rm -rf .terraform $(PLAN) $(PLAN_JSON) $(REPORTS_DIR) $(SECURITY_REPORT_DIR)
        @$(call log,Cleaned)

gitlog: ## Show git log graph
        @git log --graph --oneline --decorate --all

# ------------------------------------------------------- Internal guards ---
.need-%:
        @command -v $* >/dev/null 2>&1 || $(call die,$* is not installed or not in PATH)

.need-init:
        @test -d .terraform || $(call die,Not initialized. Run: make init)

.need-plan:
        @test -f $(PLAN) || $(call die,Plan $(PLAN) not found. Run: make plan)

.check-protected:
ifneq ($(IS_PROTECTED),)
        @$(call die,ENV=$(ENV) is protected. Use: make plan [PLAN_ARGS=-destroy] then make apply-plan)
endif

.check-account:
ifneq ($(EXPECTED_ACCOUNT_ID),)
        @command -v aws >/dev/null 2>&1 || $(call die,aws cli is required for the account check)
        @actual=$$(aws sts get-caller-identity --query Account --output text); \
                [ "$$actual" = "$(EXPECTED_ACCOUNT_ID)" ] || \
                $(call die,AWS account mismatch - expected $(EXPECTED_ACCOUNT_ID) got $$actual)
endif

$(REPORTS_DIR):
        @mkdir -p $@
