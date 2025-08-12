# Implementation Guide: Provision a Custom VPC on Google Cloud via Terraform & GitHub Actions (OIDC)

> **Purpose**
> This document walks you through a clean, reproducible implementation to deploy a Google Cloud VPC and three regional subnets (front-end, back-end, DMZ) using Terraform, authenticated from GitHub Actions via **Workload Identity Federation (OIDC)**. Each step includes a brief explanation and exact commands/snippets.

---

## 0) Repository Layout (What each file does)

```
.
├── main.tf                # Terraform resources (VPC + 3 subnets)
├── variables.tf           # Inputs for project, region, CIDRs, name
├── dev.tfvars             # Dev environment values
├── prod.tfvars            # Prod environment values
├── VPC_Create_Dev.yaml    # GitHub Actions workflow for Dev
├── VPC_Create_Prod.yaml   # GitHub Actions workflow for Prod
├── check-apis.sh          # Helper to enable required Google APIs
└── OIDC_creation.ps1      # Creates WIF pool, provider, and SA for OIDC
```

> **Why:** Keeping files modular lets you switch environments by just changing the `-var-file` passed to Terraform or by running the matching workflow.

---

## 0a) Code Access (GitHub)

**Repository:** `gogo87/CICD_GCP`
**URL:** [https://github.com/gogo87/CICD\_GCP](https://github.com/gogo87/CICD_GCP)

### Clone the repo

```bash
# HTTPS
git clone https://github.com/gogo87/CICD_GCP.git

# or via SSH (requires an SSH key added to your GitHub account)
# ssh-keygen -t ed25519 -C "you@example.com"  # if you need a key
# add ~/.ssh/id_ed25519.pub to GitHub → Settings → SSH and GPG keys

git clone git@github.com:gogo87/CICD_GCP.git
cd CICD_GCP
```

### Branching & pull requests (recommended)

* Create a feature branch for changes:

  ```bash
  git checkout -b feature/my-change
  # ...edit files...
  git add -A && git commit -m "feat: describe your change"
  git push -u origin feature/my-change
  ```
* Open a Pull Request to the default branch (often `main`). If `main` is protected, PR approval + passing checks will be required before merge.

### Required repository permissions

* **Read**: to view/clone code.
* **Write**: to push branches and open PRs.
* **Maintainer/Admin** (optional): to edit branch protection, secrets, and Actions settings.

If you lack access, request it from the repo owner or open an issue in the repository.

### GitHub Actions & OIDC

Workflows in this repo authenticate to Google Cloud via **Workload Identity Federation (OIDC)**. Ensure the OIDC provider you created references this repository identity exactly:

* `attribute.repository == "gogo87/CICD_GCP"`

If you fork or rename the repo/org, update the OIDC condition and the workflow `workload_identity_provider`/`service_account` Accordingly (see Section **2**).

### Repository secrets (if generating `*.tfvars` at runtime)

If you chose not to commit `dev.tfvars`/`prod.tfvars`, create the following **Repository Secrets**:

* **Dev:** `DEV_PROJECT_ID`, `DEV_REGION`, `DEV_FRONT_CIDR`, `DEV_BACK_CIDR`, `DEV_DMZ_CIDR`
* **Prod:** `PROD_PROJECT_ID`, `PROD_REGION`, `PROD_FRONT_CIDR`, `PROD_BACK_CIDR`, `PROD_DMZ_CIDR`

> These feed the workflow step that writes `dev.tfvars`/`prod.tfvars` before running Terraform (see Section **4.3**).

### Running the workflows

* Go to **Actions** → choose **VPC\_Create\_Dev** or **VPC\_Create\_Prod** → **Run workflow** → select the branch → **Run**.
* Inspect logs for the `auth`, `terraform init/plan/apply` steps.

---

## 0b) Comment markers used in this doc

To make edits crystal clear, code blocks now include inline markers:

* `# REQUIRED:` You **must** change this value for your environment.
* `# OPTIONAL:` You can keep the default or adjust if needed.

---

## 1) Prerequisites

1. **Google Cloud** project(s) for Dev and/or Prod.
2. **Permissions (one-time setup account):**

   * To run the OIDC setup script you need project-level IAM permissions to **create** Workload Identity Pools/Providers, Service Accounts, and IAM bindings (e.g., `roles/owner` or equivalent fine-grained set during bootstrap).
3. **Tools locally (for step 2):**

   * `gcloud` CLI (authenticated to the target GCP project)
   * PowerShell (Windows/Cloud Shell PowerShell) to run `OIDC_creation.ps1`
4. **GitHub repository** hosting this Terraform code and the GitHub Actions workflows.

> **Why:** OIDC (federated identity) lets GitHub Actions authenticate to GCP **without JSON keys**.

---

## 2) Configure Workload Identity Federation (OIDC)

### 2.1 Run the OIDC setup script

Run the PowerShell script to create the **Workload Identity Pool & OIDC Provider**, a **Service Account**, and IAM bindings so your GitHub repo can impersonate that Service Account.

```powershell
# In the repo root (or wherever the script is located)
# Make sure you are authenticated with gcloud to the right project first

pwsh ./OIDC_creation.ps1
```

You will be prompted for:

* **PROJECT\_ID**: Target GCP project (e.g., `cicd-dev-123456`).
* **POOL\_ID**: A name you choose (e.g., `oidc-pool`).
* **PROVIDER\_ID**: A name you choose (e.g., `oidc-provider`).
* **GITHUB\_REPO**: `owner/repository` (e.g., `your-org/your-repo`).
* **SERVICE\_ACCOUNT\_NAME**: A name you choose (e.g., `terraform-ci`).

**What the script does (brief):**

* Creates a **Workload Identity Pool** and **OIDC Provider** pointing at GitHub’s issuer `https://token.actions.githubusercontent.com`.
* Creates a **Service Account** and gives your GitHub repo permission to **impersonate** it via `roles/iam.workloadIdentityUser`.
* Enables the required API for minting short-lived credentials.

> **Security note:** The sample script may grant **Project Owner** to the CI Service Account for simplicity. For production, reduce to the **least‑privilege** set. For this VPC/subnet use case, a minimal set can be:
>
> * `roles/compute.networkAdmin` (manage networks/subnets)
> * `roles/compute.securityAdmin` (if you will add firewall rules later)
> * `roles/iam.serviceAccountTokenCreator` may be required in some federated setups
>
> Adjust according to the resources you plan to create.

### 2.2 Capture values for GitHub Actions

From the script output (or from the Google Cloud Console), note:

* **Workload Identity Provider resource name**:
  `projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<POOL_ID>/providers/<PROVIDER_ID>`
* **Service Account email**:
  `<SERVICE_ACCOUNT_NAME>@<PROJECT_ID>.iam.gserviceaccount.com`

You will paste these into the workflow `with:` block as shown in step 4.

---

## 3) Terraform Configuration

### 3.1 Inputs (`variables.tf`)

Key inputs:

* `project_id` *(string)* — target GCP project.
* `region` *(string)* — e.g., `us-central1` (the provider infers the zone as `<region>-a`).
* `front_cidr`, `back_cidr`, `DMZ_cidr` *(CIDR strings)* — each subnet’s IP range.
* `name` *(string)* — used to prefix/name the VPC.

### 3.2 Resources (`main.tf`)

* **Provider** is configured with `project = var.project_id` and `zone = "${var.region}-a"` (region inferred from zone).
* **VPC**: `google_compute_network` named `${var.name}-vpc` with `auto_create_subnetworks = false` (custom mode).
* **Subnets** (regional): three `google_compute_subnetwork` resources named `front-end-subnet`, `back-end-subnet`, and `dmz-subnet`, each using its corresponding CIDR input and attached to the VPC.

### 3.3 Environment values (`*.tfvars`)

* **Dev** (`dev.tfvars`) — sample:

REQUIRED: set to your GCP project ID

project\_id = "cicd-dev-xxxxxx"

REQUIRED: choose a supported region (e.g., us-central1, us-east1)

region     = "us-central1"

REQUIRED: set unique, non-overlapping CIDR ranges

front\_cidr = "10.0.0.0/24"
back\_cidr  = "11.0.0.0/24"
DMZ\_cidr   = "12.0.0.0/24"

OPTIONAL: a short name used for resource prefixes (VPC will be "\${name}-vpc")

name       = "dev"

* **Prod** (`prod.tfvars`) — sample:

REQUIRED: set to your GCP project ID

project\_id = "cicd-prod-xxxxxx"

REQUIRED: choose a supported region for prod

region     = "us-east1"

REQUIRED: set unique, non-overlapping CIDR ranges (do not overlap with Dev)

front\_cidr = "192.168.1.0/24"
back\_cidr  = "192.168.2.0/24"
DMZ\_cidr   = "192.168.3.0/24"

OPTIONAL: a short name used for resource prefixes (VPC will be "\${name}-vpc")

name       = "prod"

> **Tip:** Keep `*.tfvars` out of version control (use `.gitignore`). If you don’t commit them, add a workflow step to **generate** them from GitHub Secrets at runtime (see step 4.3).

---

## 4) GitHub Actions (CI/CD)

### 4.1 Dev workflow

A minimal Dev workflow authenticates to GCP via OIDC, sets up Terraform, then runs `init`, `plan`, and `apply` using `dev.tfvars`:

```yaml
name: VPC_Create_Dev

permissions:
  id-token: write  # REQUIRED: needed for OIDC
  contents: read

on:
  workflow_dispatch:

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repo
        uses: actions/checkout@v4

      - name: Auth to Google Cloud via OIDC
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: >-
            projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<POOL_ID>/providers/<PROVIDER_ID>  # REQUIRED: paste your exact WIF provider resource name
          service_account: <SERVICE_ACCOUNT_EMAIL>  # REQUIRED: CI service account email (e.g., terraform-ci@PROJECT_ID.iam.gserviceaccount.com)
          token_format: access_token  # OPTIONAL: leave as access_token unless you explicitly need id_token
          create_credentials_file: true  # REQUIRED: generate ADC file for Terraform/Google Provider

      - name: (Optional) Enable required APIs
        run: bash ./check-apis.sh "$(grep -E '^project_id' dev.tfvars | cut -d '"' -f2)"  # REQUIRED if APIs not already enabled

      - name: Set up Terraform
        uses: hashicorp/setup-terraform@v3

      - name: Terraform Init
        run: terraform init

      - name: Terraform Plan (Dev)
        run: terraform plan -var-file=dev.tfvars  # REQUIRED: ensure dev.tfvars exists (committed or generated in a prior step)

      - name: Terraform Apply (Dev)
        run: terraform apply -var-file=dev.tfvars -auto-approve
```

### 4.2 Prod workflow

Identical pattern pointing to `prod.tfvars`.

```yaml
# ...same preface as Dev...
      - name: Terraform Plan (Prod)
        run: terraform plan -var-file=prod.tfvars
      - name: Terraform Apply (Prod)
        run: terraform apply -var-file=prod.tfvars -auto-approve
```

### 4.3 If your `*.tfvars` are **not** committed

Generate them at runtime from GitHub Secrets to keep sensitive values out of the repo:

```yaml
      - name: Create dev.tfvars from secrets  # REQUIRED if you don't commit dev.tfvars
        run: |
          # Ensure these repository secrets exist: DEV_PROJECT_ID, DEV_REGION, DEV_FRONT_CIDR, DEV_BACK_CIDR, DEV_DMZ_CIDR
          cat > dev.tfvars <<EOF
          project_id = "${{ secrets.DEV_PROJECT_ID }}"   # REQUIRED
          region     = "${{ secrets.DEV_REGION }}"       # REQUIRED
          front_cidr = "${{ secrets.DEV_FRONT_CIDR }}"   # REQUIRED
          back_cidr  = "${{ secrets.DEV_BACK_CIDR }}"    # REQUIRED
          DMZ_cidr   = "${{ secrets.DEV_DMZ_CIDR }}"     # REQUIRED
          name       = "dev"                              # OPTIONAL
          EOF
```

> **Why:** The runner needs the file present at execution time if it’s referenced by `-var-file`. This pattern avoids committing environment config.

---

## 5) Enabling Required APIs

You can enable required APIs automatically in CI (see step **4.1**) or once per project locally:

```bash
bash ./check-apis.sh <PROJECT_ID>
```

> **Why:** The VPC/subnet resources use the Compute API. Enabling it up front prevents `API not enabled` errors at `terraform apply` time.

---

## 6) Validate the Deployment

After a successful run (Dev example):

```bash
# List VPCs
gcloud compute networks list --project="$(grep -E '^project_id' dev.tfvars | cut -d '"' -f2)"

# Inspect subnets in the target region
REGION="$(grep -E '^region' dev.tfvars | cut -d '"' -f2)"
gcloud compute networks subnets list --regions "$REGION" \
  --project="$(grep -E '^project_id' dev.tfvars | cut -d '"' -f2)"
```

You should see one VPC named `${name}-vpc` and three subnets:

* `front-end-subnet` → `front_cidr`
* `back-end-subnet`  → `back_cidr`
* `dmz-subnet`       → `DMZ_cidr`

---

## 7) Destroy / Rollback (per environment)

To remove all provisioned resources for a given environment:

```bash
terraform destroy -var-file=dev.tfvars -auto-approve
# or
terraform destroy -var-file=prod.tfvars -auto-approve
```

> **Why:** Keeping the infra declarative means you can also tear it down cleanly from the same code.

---

## 8) Troubleshooting Tips

* **OIDC auth fails / ********`permission denied`********:**

  * Verify the `workload_identity_provider` **full resource name** and `service_account` email in the workflow.
  * Ensure the Service Account has **`iam.workloadIdentityUser`** binding **from** the GitHub repo’s principal (`attribute.repository==owner/repo`).
  * If using organization/enterprise runners, confirm the repo matches the attribute condition.

* **`API not enabled`**\*\* during apply:\*\*

  * Run the helper script or enable `compute.googleapis.com` in Cloud Console/CLI.

* **`-var-file`**\*\* not found in CI:\*\*

  * Either commit sanitized `*.tfvars` or generate them from secrets (see 4.3).

* **Least privilege hardening:**

  * Replace broad roles with targeted ones for the Service Account (e.g., `roles/compute.networkAdmin`).

* **State storage:**

  * This minimal setup uses **local state** on the runner. For team workflows, configure a **GCS backend** to persist state between runs.

  ```hcl
  ```

# backend example (in a separate backend.tf)

terraform {
backend "gcs" {
bucket = "\<YOUR\_STATE\_BUCKET>"  # REQUIRED: existing GCS bucket for Terraform state
prefix = "terraform/state"      # OPTIONAL: folder path within the bucket
}
}

```

---

## 9) Appendix A — Variables Reference

| Variable     | Type   | Example        | Notes                               |
| ------------ | ------ | -------------- | ----------------------------------- |
| `project_id` | string | `cicd-dev-123` | Target GCP project ID               |
| `region`     | string | `us-central1`  | Provider infers `zone = <region>-a` |
| `front_cidr` | string | `10.0.0.0/24`  | Front-end subnet CIDR               |
| `back_cidr`  | string | `11.0.0.0/24`  | Back-end subnet CIDR                |
| `DMZ_cidr`   | string | `12.0.0.0/24`  | DMZ subnet CIDR                     |
| `name`       | string | `dev`          | VPC will be named `${name}-vpc`     |

---

## 10) Appendix B — What gets created

- **1× VPC** in **custom mode** (no auto subnets)
- **3× Subnets** (front/back/DMZ) in the specified region


```
