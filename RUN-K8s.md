# RUN-K8s.md — Nextcloud App Store: Air-Gapped Kubernetes Operator Runbook

**Audience:** Operations engineers deploying and maintaining the Nextcloud App Store on an air-gapped Kubernetes cluster.  
**Scope:** This guide takes you from zero — nothing running anywhere — to a fully operational air-gapped stack.  
**Commercial side:** The internet-connected Docker Compose side (bundle preparation) is covered in full in `RUN-DOCKER.md`. This document gives a brief summary of the bundle-build steps and then focuses entirely on the Kubernetes deployment.

---

## Architecture Overview

```
┌─────────────────────────────┐        ┌────────────────────────────────────┐
│  COMMERCIAL (internet)       │        │  AIR-GAPPED KUBERNETES CLUSTER     │
│                             │        │  namespace: nextcloud-appstore      │
│  Docker Compose             │ bundle │                                    │
│  ┌─────────────────────┐   │──────▶ │  01 namespace                       │
│  │ App Store (Django)  │   │        │  02 secrets                         │
│  │ PostgreSQL          │   │        │  03 configmap                       │
│  │ Nginx (TLS proxy)   │   │        │  04 PVCs                            │
│  │ File server         │   │        │  05 postgres (App Store DB)         │
│  │ RustFS (S3)         │   │        │  06 appstore (Django/uWSGI)         │
│  └─────────────────────┘   │        │  07 nginx (TLS NodePort 30080/30443)│
│                             │        │  08 fileserver (NodePort 30081/30444│
│  Produces:                  │        │  09-tls-secret.yaml (from certs)   │
│  - Docker image tarballs    │        │  10 import-db Job                   │
│  - DB dump (.sql.gz)        │        │  11 configure-nextcloud Job         │
│  - App archives (.tar.gz)   │        │  12 postgres-nc (Nextcloud DB)     │
│  - k8s TLS secret YAML      │        │  13 nextcloud (NodePort 30082)     │
└─────────────────────────────┘        │  14 rustfs (NodePort 30900/30901)  │
                                       │  15 rustfs-init Job                 │
                                       └────────────────────────────────────┘
```

### NodePort Access URLs

Replace `{IP_ADDRESS}` with any Kubernetes node IP address.

| Service | NodePort | URL | Notes |
|---------|----------|-----|-------|
| App Store (HTTP redirect) | 30080 | `http://{IP_ADDRESS}:30080` | Redirects to HTTPS |
| App Store (HTTPS) | 30443 | `https://{IP_ADDRESS}:30443` | Main App Store UI |
| App Store Admin | 30443 | `https://{IP_ADDRESS}:30443/admin/` | Django admin |
| App Store API | 30443 | `https://{IP_ADDRESS}:30443/api/v1` | Nextcloud queries this |
| File Server (HTTP) | 30081 | `http://{IP_ADDRESS}:30081/apps/` | App archives |
| File Server (HTTPS) | 30444 | `https://{IP_ADDRESS}:30444/apps/` | App archives (TLS) |
| Nextcloud | 30082 | `http://{IP_ADDRESS}:30082` | Nextcloud UI |
| RustFS S3 API | 30900 | `http://{IP_ADDRESS}:30900` | S3-compatible endpoint |
| RustFS Console | 30901 | `http://{IP_ADDRESS}:30901` | Web management UI |

### Resource Requirements (per Pod)

| Workload | CPU Request | CPU Limit | Memory Request | Memory Limit | Storage |
|----------|-------------|-----------|----------------|--------------|---------|
| postgres (App Store) | 250m | 1000m | 256Mi | 1Gi | 10Gi PVC |
| appstore (x2 replicas) | 250m | 2000m | 512Mi | 2Gi | shares static/media/logs PVCs |
| nginx (x2 replicas) | 50m | 500m | 64Mi | 256Mi | shares static/media PVCs |
| fileserver | 50m | 500m | 64Mi | 256Mi | 50Gi PVC |
| postgres-nc | 250m | 1000m | 256Mi | 1Gi | 10Gi PVC |
| nextcloud | 250m | 2000m | 512Mi | 2Gi | 20Gi PVC |
| rustfs | 250m | 2000m | 256Mi | 2Gi | 100Gi PVC |
| **Total (steady state)** | **~1.7 cores** | **~10 cores** | **~2Gi** | **~10.5Gi** | **~212Gi** |

Minimum viable cluster: 3 nodes, 4 vCPU / 8 GB RAM each, 300 GB available storage.

---

## Manifest Apply Order

All manifests live in `airgapped/k8s/`. Apply them in numbered order.

```
01-namespace.yaml              namespace: nextcloud-appstore
02-secrets.yaml                appstore-secrets, postgres-secrets
03-configmap.yaml              appstore-config, uwsgi-config
04-pvc.yaml                    postgres, static, media, logs, fileserver-apps PVCs
05-postgres.yaml               App Store PostgreSQL + ClusterIP service
06-appstore.yaml               Django/uWSGI Deployment + ClusterIP service
07-nginx.yaml                  nginx TLS proxy + NodePort 30080/30443
08-fileserver.yaml             nginx file server + NodePort 30081/30444
k8s/09-tls-secret.yaml         appstore-tls secret (generated, not numbered in airgapped/k8s/)
10-import-db-job.yaml          Job: restore App Store DB dump
11-configure-nextcloud-job.yaml Job: run occ to point Nextcloud at this App Store
12-postgres-nc.yaml            Nextcloud PostgreSQL + Secret + PVC + ClusterIP
13-nextcloud.yaml              Nextcloud:stable-apache + Secret + PVC + NodePort 30082
14-rustfs.yaml                 RustFS S3 store + Secret + PVC + NodePort 30900/30901
15-rustfs-init-job.yaml        Job: create buckets in RustFS
```

> **imagePullPolicy: Never** is set on every workload manifest. Every image must be pre-loaded into the container runtime on every node before any manifest is applied.

---

## Phase 1 — Build the Bundle on the Commercial Side

> This phase runs on an **internet-connected host** running Docker Compose. Full step-by-step instructions are in `RUN-DOCKER.md`. This is a brief summary.

### 1.1 What to run on the commercial side

```bash
# 1. Clone repo and configure
git clone <repo-url>
cd Nextcloud-appstore
cp .env.example .env
#    Edit .env: set NEXTCLOUD_VERSION, passwords, SERVER_CN / SERVER_ALT_NAMES

# 2. Generate TLS certificates (also writes k8s/09-tls-secret.yaml)
bash k8s/generate-certs.sh

# 3. Start Docker Compose stack
docker compose up -d
docker compose ps   # all services should be Up

# 4. Sync app catalog from apps.nextcloud.com
bash scripts/sync-apps.sh

# 5. Download approved app archives
bash scripts/mirror-apps/mirror-apps.sh

# 6. Export the database
bash scripts/db/export-db.sh

# 7. Build the full bundle (images + DB + archives + TLS secret YAML)
bash scripts/export-bundle.sh --nc-version 30.0.0
```

### 1.2 What you end up with

```
airgapped/
  images/
    nextcloudappstore-latest.tar.gz
    postgres-15-alpine.tar.gz
    nginx-alpine.tar.gz
    nextcloud-stable-apache.tar.gz
    rustfs-rustfs-latest.tar.gz
    minio-mc-latest.tar.gz
    busybox-latest.tar.gz
  exports/
    appstore_db_<timestamp>.sql.gz
    app-archives/files/*.tar.gz
k8s/
  09-tls-secret.yaml          ← generated by generate-certs.sh
```

These files are everything you need to bring to the air-gapped cluster. Reference `RUN-DOCKER.md` for the commercial side in depth.

---

## Phase 2 — Prepare the Air-Gapped Kubernetes Cluster

### 2.1 Prerequisites on the air-gapped side

The following must be available on the air-gapped operator workstation and on each cluster node:

| Tool | Where needed | Check |
|------|--------------|-------|
| `kubectl` (1.26+) | Operator workstation | `kubectl version --client` |
| `docker` or `ctr` | Every cluster node | `docker version` or `ctr version` |
| A running K8s cluster | — | `kubectl cluster-info` |
| `kubectl` kubeconfig pointing at the cluster | Operator workstation | `kubectl get nodes` |
| A StorageClass that can provision PVCs | Cluster | `kubectl get sc` |

Verify the cluster is reachable:

```bash
kubectl cluster-info
kubectl get nodes -o wide
kubectl get sc
```

Record the **node IP address** you will use to access NodePorts. Use `kubectl get nodes -o wide` and pick the `INTERNAL-IP` or `EXTERNAL-IP` of any worker node. This IP replaces `{IP_ADDRESS}` throughout this guide.

### 2.2 Transfer the bundle to the air-gapped environment

Transfer the following from the commercial host to the air-gapped operator workstation (USB drive, secure copy, or your approved transfer method):

```
airgapped/images/*.tar.gz
airgapped/exports/appstore_db_<timestamp>.sql.gz
airgapped/exports/app-archives/files/*.tar.gz
k8s/09-tls-secret.yaml
airgapped/k8s/   (all 15 manifest files)
```

Place the repo directory at the same relative paths on the air-gapped workstation. The scripts expect `airgapped/` relative to the project root.

### 2.3 Load images onto every cluster node

**This step must be completed on every node in your cluster** before any manifests are applied. All manifests use `imagePullPolicy: Never`, meaning Kubernetes will not attempt to pull images from a registry and will fail with `ErrImageNeverPull` if the image is absent.

**Option A — Use the provided script (runs on one machine; requires Docker on that machine to be the same runtime as the nodes):**

```bash
bash airgapped/scripts/load-images.sh
```

**Option B — Manual load (run on each node, or use `docker save` / `docker load` over SSH):**

```bash
# On each cluster node — repeat for every .tar.gz in airgapped/images/
for IMAGE in airgapped/images/*.tar.gz; do
    echo "Loading ${IMAGE} ..."
    gunzip -c "${IMAGE}" | docker load
done
```

**If your nodes use containerd (k3s, RKE2, kubeadm with containerd):**

```bash
# Use ctr instead of docker (run on each node)
for IMAGE in airgapped/images/*.tar.gz; do
    echo "Loading ${IMAGE} ..."
    gunzip -c "${IMAGE}" | ctr -n k8s.io images import -
done
```

**If your nodes use a different node runtime (podman, CRI-O):**

```bash
# podman example
for IMAGE in airgapped/images/*.tar.gz; do
    gunzip -c "${IMAGE}" | podman load
done
```

### 2.4 Verify all images are present on the nodes

After loading, confirm the expected images exist. Run this on each node:

```bash
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}" | \
    grep -E "(nextcloudappstore|postgres|nginx|nextcloud|rustfs|minio/mc|busybox)"
```

Expected output (tags may vary):

```
nextcloudappstore     latest    <id>
postgres              15-alpine <id>
nginx                 alpine    <id>
nextcloud             stable-apache <id>
rustfs/rustfs         latest    <id>
minio/mc              latest    <id>
busybox               latest    <id>
```

If any image is missing, re-run the load step for that specific tarball before proceeding.

---

## Phase 3 — Configure Manifests Before Applying

### 3.1 Customise secrets

All secrets ship with placeholder base64 values. **You must update them before applying.**

The base64 default values decode to obvious placeholders:
- `appstore-secrets.SECRET_KEY` → `CHANGE_THIS_IN_PRODUCTION_use_64_char_random_string`
- `appstore-secrets.DATABASE_PASSWORD` → `changeme_production_password`
- `postgres-secrets.POSTGRES_PASSWORD` → same placeholder (must match DATABASE_PASSWORD)
- `postgres-nc-secrets.POSTGRES_PASSWORD` → `changeme_nc_password`
- `nextcloud-secrets.NEXTCLOUD_ADMIN_PASSWORD` → `ChangeThisNcAdmin`
- `nextcloud-secrets.NEXTCLOUD_DB_PASSWORD` → same as postgres-nc-secrets (must match)
- `rustfs-secrets.RUSTFS_ACCESS_KEY` → `rustfsadmin`
- `rustfs-secrets.RUSTFS_SECRET_KEY` → `ChangeThisRustFsSecret`

**Method A — Edit YAML directly (good for offline environments):**

Generate new values and base64-encode them:

```bash
# Generate a 64-character secret key
SECRET_KEY=$(LC_CTYPE=C tr -dc 'a-zA-Z0-9_-' < /dev/urandom | head -c 64)
echo -n "${SECRET_KEY}" | base64

# Encode a password
echo -n "MyStrongPassword123!" | base64
```

Edit `airgapped/k8s/02-secrets.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: appstore-secrets
  namespace: nextcloud-appstore
type: Opaque
data:
  SECRET_KEY: <base64-of-64-char-random-string>
  DATABASE_PASSWORD: <base64-of-db-password>     # same value in postgres-secrets

---
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secrets
  namespace: nextcloud-appstore
type: Opaque
data:
  POSTGRES_USER: bmV4dGNsb3VkYXBwc3RvcmU=        # "nextcloudappstore" — leave as-is
  POSTGRES_DB: bmV4dGNsb3VkYXBwc3RvcmU=           # "nextcloudappstore" — leave as-is
  POSTGRES_PASSWORD: <same-base64-as-DATABASE_PASSWORD>
```

Edit `airgapped/k8s/12-postgres-nc.yaml` for Nextcloud's database:

```yaml
data:
  POSTGRES_USER: bmV4dGNsb3Vk    # "nextcloud" — leave as-is
  POSTGRES_DB: bmV4dGNsb3Vk      # "nextcloud" — leave as-is
  POSTGRES_PASSWORD: <base64-of-nc-db-password>
```

Edit `airgapped/k8s/13-nextcloud.yaml` for Nextcloud admin credentials:

```yaml
data:
  NEXTCLOUD_ADMIN_USER: <base64-of-admin-username>
  NEXTCLOUD_ADMIN_PASSWORD: <base64-of-admin-password>
  NEXTCLOUD_DB_PASSWORD: <same-base64-as-postgres-nc-secrets-POSTGRES_PASSWORD>
```

Edit `airgapped/k8s/14-rustfs.yaml` for RustFS credentials:

```yaml
data:
  RUSTFS_ACCESS_KEY: <base64-of-access-key>
  RUSTFS_SECRET_KEY: <base64-of-secret-key>   # minimum 8 characters
```

**Method B — Use kubectl dry-run (requires cluster access, replaces secrets in place):**

```bash
NS=nextcloud-appstore

# Generate and apply appstore-secrets
kubectl create secret generic appstore-secrets \
  --from-literal=SECRET_KEY="$(LC_CTYPE=C tr -dc 'a-zA-Z0-9_-' < /dev/urandom | head -c 64)" \
  --from-literal=DATABASE_PASSWORD="YourAppStoreDBPassword" \
  -n "${NS}" --dry-run=client -o yaml | kubectl apply -f -

# postgres-secrets (POSTGRES_PASSWORD must match DATABASE_PASSWORD above)
kubectl create secret generic postgres-secrets \
  --from-literal=POSTGRES_USER="nextcloudappstore" \
  --from-literal=POSTGRES_DB="nextcloudappstore" \
  --from-literal=POSTGRES_PASSWORD="YourAppStoreDBPassword" \
  -n "${NS}" --dry-run=client -o yaml | kubectl apply -f -

# postgres-nc-secrets
kubectl create secret generic postgres-nc-secrets \
  --from-literal=POSTGRES_USER="nextcloud" \
  --from-literal=POSTGRES_DB="nextcloud" \
  --from-literal=POSTGRES_PASSWORD="YourNextcloudDBPassword" \
  -n "${NS}" --dry-run=client -o yaml | kubectl apply -f -

# nextcloud-secrets (NEXTCLOUD_DB_PASSWORD must match postgres-nc-secrets)
kubectl create secret generic nextcloud-secrets \
  --from-literal=NEXTCLOUD_ADMIN_USER="admin" \
  --from-literal=NEXTCLOUD_ADMIN_PASSWORD="YourNextcloudAdminPassword" \
  --from-literal=NEXTCLOUD_DB_PASSWORD="YourNextcloudDBPassword" \
  -n "${NS}" --dry-run=client -o yaml | kubectl apply -f -

# rustfs-secrets
kubectl create secret generic rustfs-secrets \
  --from-literal=RUSTFS_ACCESS_KEY="rustfsadmin" \
  --from-literal=RUSTFS_SECRET_KEY="YourRustFsSecretKey" \
  -n "${NS}" --dry-run=client -o yaml | kubectl apply -f -
```

> **Critical:** `DATABASE_PASSWORD` in `appstore-secrets` and `POSTGRES_PASSWORD` in `postgres-secrets` must be identical. `NEXTCLOUD_DB_PASSWORD` in `nextcloud-secrets` and `POSTGRES_PASSWORD` in `postgres-nc-secrets` must be identical. Mismatches cause connection failures that are not obvious from pod logs.

### 3.2 Adjust storageClassName if needed

Every PVC in `04-pvc.yaml`, `12-postgres-nc.yaml`, `13-nextcloud.yaml`, and `14-rustfs.yaml` has a commented-out `storageClassName` line. By default, PVCs use the cluster's default StorageClass.

Check what StorageClasses are available:

```bash
kubectl get storageclass
```

If your cluster has no default StorageClass, or you want to use a specific one (e.g., `local-path`, `nfs-client`, `standard`), uncomment and edit the `storageClassName` line in each PVC:

```yaml
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: local-path    # <-- uncomment and set to your StorageClass name
```

Files to edit:
- `airgapped/k8s/04-pvc.yaml` — postgres, static, media, logs, fileserver-apps PVCs
- `airgapped/k8s/12-postgres-nc.yaml` — postgres-nc PVC
- `airgapped/k8s/13-nextcloud.yaml` — nextcloud-data PVC
- `airgapped/k8s/14-rustfs.yaml` — rustfs-data PVC (100Gi — confirm you have this capacity)

> **Note on access modes:** All PVCs use `ReadWriteOnce`. If your StorageClass only supports `ReadWriteMany`, change the accessMode. If you need multiple replicas of the appstore or nginx pods to share storage, you need `ReadWriteMany` on the static, media, and logs PVCs.

### 3.3 Adjust NodePorts if they conflict

The default NodePorts are:

| Service | Port | NodePort |
|---------|------|----------|
| nginx (HTTP) | 80 | 30080 |
| nginx (HTTPS) | 443 | 30443 |
| fileserver (HTTP) | 80 | 30081 |
| fileserver (HTTPS) | 443 | 30444 |
| nextcloud (HTTP) | 80 | 30082 |
| rustfs (S3 API) | 9000 | 30900 |
| rustfs (Console) | 9001 | 30901 |

If any of these conflict with existing services on your cluster, edit the `nodePort` field in the relevant service manifest. NodePorts must be in the range 30000–32767 (default Kubernetes range).

```bash
# Check for port conflicts
kubectl get svc --all-namespaces | grep NodePort
```

### 3.4 Generate TLS certificates and apply the TLS secret

The TLS secret `appstore-tls` contains:
- `tls.crt` — full certificate chain (server + intermediate + root CA)
- `tls.key` — server private key
- `ca.crt` — CA chain (used by Nextcloud to trust the App Store TLS)

This secret is consumed by:
- `07-nginx.yaml` — mounts `tls.crt` and `tls.key` for the App Store HTTPS endpoint
- `08-fileserver.yaml` — mounts `tls.crt` and `tls.key` for the file server HTTPS endpoint
- `13-nextcloud.yaml` — mounts `ca.crt` at `/tmp/appstore-certs/root-ca.crt` so Nextcloud can verify the App Store TLS cert

**Step 1: Generate certs on the commercial side** (if not already done — these were generated when running `RUN-DOCKER.md`).

```bash
# On the commercial host — include your cluster node IP in the alt names
SERVER_CN="192.168.1.100" \
SERVER_ALT_NAMES="IP:192.168.1.100,DNS:localhost,DNS:appstore.local" \
bash k8s/generate-certs.sh
```

This writes `k8s/09-tls-secret.yaml` automatically.

**Step 2: Transfer `k8s/09-tls-secret.yaml`** to the air-gapped workstation (it's just a YAML file with base64 values, safe to copy).

**Step 3: Apply the TLS secret** (must be applied before nginx, fileserver, and nextcloud):

```bash
kubectl apply -f k8s/09-tls-secret.yaml
```

Verify it exists:

```bash
kubectl get secret appstore-tls -n nextcloud-appstore
kubectl describe secret appstore-tls -n nextcloud-appstore
# Should show keys: tls.crt, tls.key, ca.crt
```

> **If you need to regenerate certs after initial deployment** (e.g., wrong IP in SAN), regenerate on the commercial side with the correct `SERVER_ALT_NAMES`, transfer the new `09-tls-secret.yaml`, apply it, then do a rolling restart of nginx and fileserver: `kubectl rollout restart deployment/nginx deployment/fileserver -n nextcloud-appstore`.

### 3.5 Update the App Store API URL in the configure-nextcloud job

Before applying `11-configure-nextcloud-job.yaml`, update the `APPSTORE_API_URL` env var to point at your node IP:

```yaml
# In airgapped/k8s/11-configure-nextcloud-job.yaml
env:
  - name: APPSTORE_API_URL
    value: "https://192.168.1.100:30443/api/v1"   # <-- set your node IP
  - name: NEXTCLOUD_K8S_NAMESPACE
    value: "nextcloud-appstore"                    # namespace where Nextcloud runs
  - name: NEXTCLOUD_K8S_POD_SELECTOR
    value: "app=nextcloud"                         # pod selector for Nextcloud
  - name: NEXTCLOUD_K8S_CONTAINER
    value: "nextcloud"                             # container name
```

Also update the `NEXTCLOUD_TRUSTED_DOMAINS` env var in `airgapped/k8s/13-nextcloud.yaml` to include your node IP:

```yaml
- name: NEXTCLOUD_TRUSTED_DOMAINS
  value: "localhost nextcloud nextcloud-service nextcloud.local 192.168.1.100"
```

---

## Phase 4 — Deploy the Full Stack

All commands in this phase run from the operator workstation and assume `kubectl` is configured to reach the air-gapped cluster.

### Step 1 — Apply the namespace

```bash
kubectl apply -f airgapped/k8s/01-namespace.yaml

# Verify
kubectl get namespace nextcloud-appstore
```

### Step 2 — Apply secrets, configmap, and PVCs

```bash
kubectl apply -f airgapped/k8s/02-secrets.yaml
kubectl apply -f airgapped/k8s/03-configmap.yaml
kubectl apply -f airgapped/k8s/04-pvc.yaml
```

Verify secrets:

```bash
kubectl get secrets -n nextcloud-appstore
# Expected: appstore-secrets, postgres-secrets, appstore-tls (from step 3.4)
```

Verify PVCs (they will be in Pending state until a pod binds them, which is normal):

```bash
kubectl get pvc -n nextcloud-appstore
# Expected STATUS: Pending (normal before first pod that uses them is created)
```

Apply the TLS secret if not already done:

```bash
kubectl apply -f k8s/09-tls-secret.yaml
kubectl get secret appstore-tls -n nextcloud-appstore
```

### Step 3 — Deploy App Store PostgreSQL and wait for Ready

```bash
kubectl apply -f airgapped/k8s/05-postgres.yaml

# Wait for the postgres pod to be Ready (readiness probe: pg_isready)
kubectl wait --for=condition=ready pod \
    -l app=postgres \
    -n nextcloud-appstore \
    --timeout=180s

# Confirm
kubectl get pods -n nextcloud-appstore -l app=postgres
```

If the pod does not become Ready within 180 seconds:

```bash
kubectl describe pod -l app=postgres -n nextcloud-appstore
kubectl logs -l app=postgres -n nextcloud-appstore
```

Common causes: PVC not bound (StorageClass issue), image not loaded on that node (`ErrImageNeverPull`).

### Step 4 — Deploy App Store, nginx, and fileserver

```bash
kubectl apply -f airgapped/k8s/06-appstore.yaml
kubectl apply -f airgapped/k8s/07-nginx.yaml
kubectl apply -f airgapped/k8s/08-fileserver.yaml
```

Wait for all pods:

```bash
# appstore has an initContainer that waits for postgres — this is expected
kubectl wait --for=condition=ready pod \
    -l app=appstore \
    -n nextcloud-appstore \
    --timeout=300s

kubectl wait --for=condition=ready pod \
    -l app=nginx \
    -n nextcloud-appstore \
    --timeout=120s

kubectl wait --for=condition=ready pod \
    -l app=fileserver \
    -n nextcloud-appstore \
    --timeout=120s
```

The `appstore` Deployment runs 2 replicas. The `nginx` Deployment runs 2 replicas.

> **uWSGI protocol note:** The appstore container exposes port 8000 using the uWSGI binary protocol, not HTTP. nginx uses `uwsgi_pass` to communicate with it — this is not a standard HTTP proxy. If you see nginx 502 errors, check that the appstore pods are ready and listening on port 8000 with `kubectl exec` (see troubleshooting section).

### Step 5 — Import the App Store database

The database dump must be copied into the postgres pod before the import job runs.

```bash
# Get the postgres pod name
PG_POD=$(kubectl get pod -l app=postgres -n nextcloud-appstore \
    -o jsonpath='{.items[0].metadata.name}')
echo "Postgres pod: ${PG_POD}"

# Copy the dump file (use the timestamped filename from your bundle)
kubectl cp airgapped/exports/appstore_db_<timestamp>.sql.gz \
    nextcloud-appstore/${PG_POD}:/tmp/appstore_db.sql.gz

# Verify the file arrived
kubectl exec -n nextcloud-appstore ${PG_POD} -- ls -lh /tmp/appstore_db.sql.gz
```

Apply the import job:

```bash
kubectl apply -f airgapped/k8s/10-import-db-job.yaml
```

Watch the import job logs:

```bash
kubectl wait --for=condition=complete job/import-appstore-db \
    -n nextcloud-appstore \
    --timeout=300s

kubectl logs job/import-appstore-db -n nextcloud-appstore
# Expected last line: "Database import complete."
```

If the job fails:

```bash
kubectl describe job import-appstore-db -n nextcloud-appstore
kubectl logs job/import-appstore-db -n nextcloud-appstore
```

Common failure: dump file not found at `/tmp/appstore_db.sql.gz` — confirm the `kubectl cp` step succeeded and the filename is exactly `appstore_db.sql.gz` inside the pod.

> **If you need to re-run the import job** (e.g., after a failed attempt), delete the old job first: `kubectl delete job import-appstore-db -n nextcloud-appstore`, then re-apply.

### Step 6 — Deploy Nextcloud PostgreSQL and wait for Ready

```bash
kubectl apply -f airgapped/k8s/12-postgres-nc.yaml

kubectl wait --for=condition=ready pod \
    -l app=postgres-nc \
    -n nextcloud-appstore \
    --timeout=180s

kubectl get pods -n nextcloud-appstore -l app=postgres-nc
```

### Step 7 — Deploy Nextcloud and wait for first-boot

Nextcloud's first boot runs the installer, which creates the database schema, configures itself, and can take 60–120 seconds.

```bash
kubectl apply -f airgapped/k8s/13-nextcloud.yaml

# The initContainer waits for postgres-nc-service before starting Nextcloud
# The livenessProbe initialDelaySeconds is 90 — give it time
kubectl wait --for=condition=ready pod \
    -l app=nextcloud \
    -n nextcloud-appstore \
    --timeout=300s
```

Stream the logs during first boot to see progress:

```bash
kubectl logs -f deployment/nextcloud -n nextcloud-appstore
```

Look for lines like `Nextcloud was successfully installed` before the pod becomes ready.

### Step 8 — Copy app archives to the fileserver pod

This populates the fileserver with the mirrored app packages so Nextcloud can download them without internet access.

```bash
FS_POD=$(kubectl get pod -l app=fileserver -n nextcloud-appstore \
    -o jsonpath='{.items[0].metadata.name}')
echo "Fileserver pod: ${FS_POD}"

# Copy all .tar.gz app archives
kubectl cp airgapped/exports/app-archives/files/. \
    nextcloud-appstore/${FS_POD}:/srv/apps/

# Verify (directory listing should show your app archives)
kubectl exec -n nextcloud-appstore ${FS_POD} -- ls -lh /srv/apps/
```

Test that the fileserver serves the files:

```bash
# From operator workstation (replace IP)
curl -sk https://192.168.1.100:30444/apps/ | grep -i "tar.gz" | head -5
```

### Step 9 — Deploy RustFS and run the bucket init job

```bash
kubectl apply -f airgapped/k8s/14-rustfs.yaml

kubectl wait --for=condition=ready pod \
    -l app=rustfs \
    -n nextcloud-appstore \
    --timeout=180s
```

Run the bucket initialiser:

```bash
kubectl apply -f airgapped/k8s/15-rustfs-init-job.yaml

kubectl wait --for=condition=complete job/rustfs-init \
    -n nextcloud-appstore \
    --timeout=120s

kubectl logs job/rustfs-init -n nextcloud-appstore
# Expected output: buckets app-archives, backups, bundles listed
```

### Step 10 — Configure Nextcloud to use the local App Store

Before applying, confirm `APPSTORE_API_URL` in `11-configure-nextcloud-job.yaml` is set to your node IP (done in Phase 3.5).

```bash
kubectl apply -f airgapped/k8s/11-configure-nextcloud-job.yaml

kubectl wait --for=condition=complete job/configure-nextcloud \
    -n nextcloud-appstore \
    --timeout=120s

kubectl logs job/configure-nextcloud -n nextcloud-appstore
# Expected last line: "Nextcloud App Store configuration complete."
```

The job runs `occ config:system:set appstoreenabled --value=true` and `occ config:system:set appstoreurl --value="https://192.168.1.100:30443/api/v1"` inside the Nextcloud pod.

If the job fails to find the Nextcloud pod, verify:

```bash
kubectl get pod -l app=nextcloud -n nextcloud-appstore
# Confirm the pod selector matches NEXTCLOUD_K8S_POD_SELECTOR in the job env
```

> **If you need to re-run the configure job:** `kubectl delete job configure-nextcloud -n nextcloud-appstore`, edit the YAML if needed, then re-apply.

### Step 11 — Verify all pods are running

```bash
kubectl get pods -n nextcloud-appstore -o wide
```

Expected output (all pods Running, all containers Ready):

```
NAME                           READY   STATUS      RESTARTS   AGE
postgres-<hash>                1/1     Running     0          10m
appstore-<hash>-<hash>         1/1     Running     0          8m
appstore-<hash>-<hash>         1/1     Running     0          8m
nginx-<hash>-<hash>            1/1     Running     0          7m
nginx-<hash>-<hash>            1/1     Running     0          7m
fileserver-<hash>              1/1     Running     0          7m
postgres-nc-<hash>             1/1     Running     0          5m
nextcloud-<hash>               1/1     Running     0          4m
rustfs-<hash>                  1/1     Running     0          2m
import-appstore-db-<hash>      0/1     Completed   0          9m
rustfs-init-<hash>             0/1     Completed   0          1m
configure-nextcloud-<hash>     0/1     Completed   0          3m
```

Completed jobs (`STATUS: Completed`) are expected and correct.

---

## Phase 5 — Validate and Operate

### 5.1 Check all pods

```bash
kubectl get pods -n nextcloud-appstore
kubectl get pods -n nextcloud-appstore -o wide | grep -v Completed
```

All running pods should show `1/1 Running` (or `2/2` if a pod has sidecars).

### 5.2 Check all services and NodePorts

```bash
kubectl get svc -n nextcloud-appstore
```

Expected:

```
NAME                  TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)
postgres-service      ClusterIP   10.x.x.x        <none>        5432/TCP
appstore-service      ClusterIP   10.x.x.x        <none>        8000/TCP
nginx-service         NodePort    10.x.x.x        <none>        443:30443/TCP,80:30080/TCP
fileserver-service    NodePort    10.x.x.x        <none>        443:30444/TCP,80:30081/TCP
nextcloud-service     NodePort    10.x.x.x        <none>        80:30082/TCP
rustfs-service        NodePort    10.x.x.x        <none>        9000:30900/TCP,9001:30901/TCP
postgres-nc-service   ClusterIP   10.x.x.x        <none>        5432/TCP
```

### 5.3 Test the App Store HTTPS endpoint

```bash
NODE_IP="192.168.1.100"    # replace with your node IP

# Health check (HTTP — should redirect)
curl -v http://${NODE_IP}:30080/health/

# HTTPS health check (self-signed cert — use -k)
curl -sk https://${NODE_IP}:30443/health/
# Expected: OK

# API endpoint
curl -sk https://${NODE_IP}:30443/api/v1/platform/8/apps.json | python3 -m json.tool | head -30
# Should return JSON with app listings

# App Store UI
echo "Browse to: https://${NODE_IP}:30443"
```

### 5.4 Test the fileserver

```bash
NODE_IP="192.168.1.100"

# HTTP listing
curl -s http://${NODE_IP}:30081/apps/ | grep -i "tar.gz" | head -5

# HTTPS listing
curl -sk https://${NODE_IP}:30444/apps/ | grep -i "tar.gz" | head -5
```

If the listing is empty, revisit Phase 4 Step 8 to confirm app archives were copied to `/srv/apps/`.

### 5.5 Test Nextcloud

```bash
NODE_IP="192.168.1.100"

# Status check
curl -s http://${NODE_IP}:30082/status.php
# Expected JSON with "installed":true, "version":"30.x.x"

echo "Log in at: http://${NODE_IP}:30082"
echo "Username: admin (or whatever you set in nextcloud-secrets)"
```

After logging in:
1. Go to **Apps** in the top navigation.
2. The Apps page should load and show app listings from your local App Store.
3. If it shows "Could not connect to the App Store" — see troubleshooting section 5.8.

To verify the App Store URL is configured in Nextcloud:

```bash
NC_POD=$(kubectl get pod -l app=nextcloud -n nextcloud-appstore \
    -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n nextcloud-appstore ${NC_POD} -- \
    sudo -u www-data php occ config:system:get appstoreurl
# Expected: https://192.168.1.100:30443/api/v1

kubectl exec -n nextcloud-appstore ${NC_POD} -- \
    sudo -u www-data php occ config:system:get appstoreenabled
# Expected: true
```

### 5.6 Test RustFS

```bash
NODE_IP="192.168.1.100"

# S3 health check
curl -s http://${NODE_IP}:30900/minio/health/live
# Expected: 200 OK (empty body)

echo "RustFS Console: http://${NODE_IP}:30901"
echo "Access key: $(kubectl get secret rustfs-secrets -n nextcloud-appstore \
    -o jsonpath='{.data.RUSTFS_ACCESS_KEY}' | base64 -d)"
echo "Secret key: $(kubectl get secret rustfs-secrets -n nextcloud-appstore \
    -o jsonpath='{.data.RUSTFS_SECRET_KEY}' | base64 -d)"
```

### 5.7 Complete validation checklist

Run through this checklist after each deployment:

```
[ ] kubectl get pods -n nextcloud-appstore  — all Running, none in CrashLoopBackOff
[ ] curl -sk https://{IP}:30443/health/     — returns "OK"
[ ] curl -sk https://{IP}:30443/api/v1/platform/8/apps.json — returns JSON
[ ] curl -sk https://{IP}:30444/apps/        — returns directory listing with .tar.gz
[ ] curl -s http://{IP}:30082/status.php     — returns {"installed":true,...}
[ ] curl -s http://{IP}:30900/minio/health/live — returns 200
[ ] Nextcloud UI login works
[ ] Nextcloud Apps page shows apps from local App Store
[ ] RustFS console accessible at http://{IP}:30901
[ ] Buckets app-archives, backups, bundles exist in RustFS
```

### 5.8 Troubleshooting table

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Pod stuck in `ErrImageNeverPull` | Image not loaded on this node | Run `docker load` for the missing image on that specific node |
| Pod stuck in `Pending` | PVC not bound | Check `kubectl get pvc -n nextcloud-appstore`; ensure StorageClass exists |
| postgres pod `CrashLoopBackOff` | Wrong secret or existing PVC with old data | Check `kubectl logs`; delete PVC if starting fresh |
| appstore pod `CrashLoopBackOff` | Can't connect to postgres; wrong DATABASE_PASSWORD | Verify passwords match between `appstore-secrets` and `postgres-secrets` |
| nginx pod `Running` but 502 Bad Gateway | appstore pods not ready; uwsgi_pass can't connect | Wait for appstore readiness; check `kubectl logs deployment/appstore` |
| nginx pod fails to start | Missing `appstore-tls` secret | Apply `k8s/09-tls-secret.yaml` first |
| import-db job fails: "dump not found" | `kubectl cp` step missed or wrong filename | Confirm `/tmp/appstore_db.sql.gz` exists in postgres pod; re-copy |
| import-db job fails: auth error | PGPASSWORD doesn't match DB password | Secrets mismatch — fix `postgres-secrets.POSTGRES_PASSWORD` |
| configure-nextcloud job fails: "No pod found" | Wrong namespace or selector | Edit `NEXTCLOUD_K8S_NAMESPACE` and `NEXTCLOUD_K8S_POD_SELECTOR` in the job YAML |
| Nextcloud "Could not connect to App Store" | Wrong appstoreurl or TLS cert not trusted | Verify `appstoreurl` via `occ config:system:get appstoreurl`; check CA cert mount |
| Nextcloud TLS error connecting to App Store | Self-signed CA not trusted by Nextcloud | Confirm `appstore-tls` secret has `ca.crt`; check Nextcloud mounts it at `/tmp/appstore-certs/root-ca.crt` |
| RustFS starts but buckets missing | rustfs-init job not run or failed | Re-apply `15-rustfs-init-job.yaml` (delete old job first) |
| rustfs-init job: "connection refused" | RustFS pod not ready | Wait for RustFS readiness, then re-apply init job |
| Fileserver shows empty `/apps/` | App archives not copied | Re-run Phase 4 Step 8 `kubectl cp` |
| NodePort not reachable from outside | Firewall / cloud security group | Open ports 30080, 30081, 30082, 30443, 30444, 30900, 30901 in your firewall |

### 5.9 Common kubectl operational commands

```bash
NS=nextcloud-appstore

# See all resources at once
kubectl get all -n ${NS}

# Live pod logs
kubectl logs -f deployment/appstore -n ${NS}
kubectl logs -f deployment/nginx -n ${NS}
kubectl logs -f deployment/nextcloud -n ${NS}
kubectl logs -f deployment/postgres -n ${NS}
kubectl logs -f deployment/rustfs -n ${NS}

# Describe a crashing pod for events
kubectl describe pod -l app=appstore -n ${NS}

# Shell into a running pod
kubectl exec -it deployment/appstore -n ${NS} -- /bin/sh
kubectl exec -it deployment/postgres -n ${NS} -- psql -U nextcloudappstore

# Run occ commands in Nextcloud
NC_POD=$(kubectl get pod -l app=nextcloud -n ${NS} -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ${NS} ${NC_POD} -- sudo -u www-data php occ config:list system
kubectl exec -n ${NS} ${NC_POD} -- sudo -u www-data php occ app:list

# View events (useful for PVC and scheduling issues)
kubectl get events -n ${NS} --sort-by='.lastTimestamp'

# Rolling restart (e.g., after secret update)
kubectl rollout restart deployment/appstore -n ${NS}
kubectl rollout restart deployment/nginx -n ${NS}
kubectl rollout status deployment/appstore -n ${NS}

# Check PVC usage
kubectl describe pvc -n ${NS}

# Check resource consumption
kubectl top pods -n ${NS}

# Delete and re-run a failed job
kubectl delete job import-appstore-db -n ${NS}
kubectl apply -f airgapped/k8s/10-import-db-job.yaml

kubectl delete job configure-nextcloud -n ${NS}
kubectl apply -f airgapped/k8s/11-configure-nextcloud-job.yaml

kubectl delete job rustfs-init -n ${NS}
kubectl apply -f airgapped/k8s/15-rustfs-init-job.yaml
```

---

## Phase 6 — Update Cycle

When the app catalog needs updating (new app versions, new apps added, or a new Nextcloud major version), follow this cycle.

### 6.1 On the commercial side — build a new bundle

```bash
# On the internet-connected Docker Compose host:

# 1. Pull latest app metadata
bash scripts/sync-apps.sh

# 2. Update the allowlist if adding new apps
#    Edit config/app-allowlist.txt

# 3. Mirror the latest app archives
bash scripts/mirror-apps/mirror-apps.sh

# 4. Export updated database
bash scripts/db/export-db.sh

# 5. Build a new bundle (new timestamp in filename)
bash scripts/export-bundle.sh --nc-version 30.0.0

# 6. If the appstore image changed (new code), rebuild and save it
docker compose build appstore
docker save nextcloudappstore:latest | gzip > airgapped/images/nextcloudappstore-latest.tar.gz
```

### 6.2 Transfer to the air-gapped cluster

Transfer the updated files:

```bash
# Transfer only what changed (minimise transfer size)
airgapped/exports/appstore_db_<new-timestamp>.sql.gz
airgapped/exports/app-archives/files/*.tar.gz      # only new/changed archives
airgapped/images/nextcloudappstore-latest.tar.gz   # only if image changed
```

### 6.3 Apply the update on the Kubernetes cluster

**Update the database:**

```bash
NS=nextcloud-appstore

# Copy new dump to postgres pod
PG_POD=$(kubectl get pod -l app=postgres -n ${NS} -o jsonpath='{.items[0].metadata.name}')
kubectl cp airgapped/exports/appstore_db_<new-timestamp>.sql.gz \
    ${NS}/${PG_POD}:/tmp/appstore_db.sql.gz

# Delete old job and re-run
kubectl delete job import-appstore-db -n ${NS} --ignore-not-found
kubectl apply -f airgapped/k8s/10-import-db-job.yaml

kubectl wait --for=condition=complete job/import-appstore-db -n ${NS} --timeout=300s
kubectl logs job/import-appstore-db -n ${NS}
```

> **Warning:** The import job runs `gunzip -c ... | psql ...` which appends to the existing database. If your dump is a full replacement (pg_dump of the entire DB), drop and recreate the database first, or use `pg_restore` with `--clean`. Check what your export script produces — if it uses `pg_dump --clean`, appending is safe. If not, exec into the postgres pod and drop/recreate the DB before importing:
> 
> ```bash
> kubectl exec -it ${PG_POD} -n ${NS} -- psql -U nextcloudappstore -c \
>     "DROP DATABASE nextcloudappstore; CREATE DATABASE nextcloudappstore OWNER nextcloudappstore;"
> ```

**Update app archives:**

```bash
FS_POD=$(kubectl get pod -l app=fileserver -n ${NS} -o jsonpath='{.items[0].metadata.name}')

# Copy new/updated archives
kubectl cp airgapped/exports/app-archives/files/. \
    ${NS}/${FS_POD}:/srv/apps/

# Verify
kubectl exec -n ${NS} ${FS_POD} -- ls -lh /srv/apps/ | tail -20
```

**Update the appstore image (if it changed):**

```bash
# Load new image on every cluster node
for NODE in node1 node2 node3; do
    ssh ${NODE} "gunzip -c /path/to/nextcloudappstore-latest.tar.gz | docker load"
done

# Rolling restart (zero-downtime with 2 replicas)
kubectl rollout restart deployment/appstore -n ${NS}
kubectl rollout status deployment/appstore -n ${NS}

# Restart nginx if nginx image also changed
kubectl rollout restart deployment/nginx -n ${NS}
```

**Verify after update:**

```bash
curl -sk https://192.168.1.100:30443/api/v1/platform/8/apps.json | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(f'{len(d[\"apps\"])} apps in catalog')"

curl -sk https://192.168.1.100:30444/apps/ | grep -c "tar.gz"
# Compare count to number of files you copied
```

---

## Appendix A — Complete Copy-Paste Deploy Sequence

Use this as a single-session deployment script reference. Replace `192.168.1.100` with your node IP and `appstore_db_<timestamp>.sql.gz` with your actual dump filename.

```bash
#!/usr/bin/env bash
set -euo pipefail

NS=nextcloud-appstore
NODE_IP="192.168.1.100"
DB_DUMP="airgapped/exports/appstore_db_20260101_120000.sql.gz"   # adjust filename

echo "=== Phase 2: Load images on nodes ==="
# (Run on each node, or via SSH)
# for IMAGE in airgapped/images/*.tar.gz; do gunzip -c "${IMAGE}" | docker load; done

echo "=== Phase 3: Apply TLS secret ==="
kubectl apply -f k8s/09-tls-secret.yaml

echo "=== Phase 4 Step 1: Namespace ==="
kubectl apply -f airgapped/k8s/01-namespace.yaml

echo "=== Phase 4 Step 2: Secrets + ConfigMap + PVCs ==="
kubectl apply -f airgapped/k8s/02-secrets.yaml
kubectl apply -f airgapped/k8s/03-configmap.yaml
kubectl apply -f airgapped/k8s/04-pvc.yaml

echo "=== Phase 4 Step 3: App Store PostgreSQL ==="
kubectl apply -f airgapped/k8s/05-postgres.yaml
kubectl wait --for=condition=ready pod -l app=postgres -n ${NS} --timeout=180s

echo "=== Phase 4 Step 4: App Store + nginx + fileserver ==="
kubectl apply -f airgapped/k8s/06-appstore.yaml
kubectl apply -f airgapped/k8s/07-nginx.yaml
kubectl apply -f airgapped/k8s/08-fileserver.yaml
kubectl wait --for=condition=ready pod -l app=appstore  -n ${NS} --timeout=300s
kubectl wait --for=condition=ready pod -l app=nginx      -n ${NS} --timeout=120s
kubectl wait --for=condition=ready pod -l app=fileserver -n ${NS} --timeout=120s

echo "=== Phase 4 Step 5: Import App Store database ==="
PG_POD=$(kubectl get pod -l app=postgres -n ${NS} -o jsonpath='{.items[0].metadata.name}')
kubectl cp "${DB_DUMP}" "${NS}/${PG_POD}:/tmp/appstore_db.sql.gz"
kubectl apply -f airgapped/k8s/10-import-db-job.yaml
kubectl wait --for=condition=complete job/import-appstore-db -n ${NS} --timeout=300s

echo "=== Phase 4 Step 6: Nextcloud PostgreSQL ==="
kubectl apply -f airgapped/k8s/12-postgres-nc.yaml
kubectl wait --for=condition=ready pod -l app=postgres-nc -n ${NS} --timeout=180s

echo "=== Phase 4 Step 7: Nextcloud (first boot ~90s) ==="
kubectl apply -f airgapped/k8s/13-nextcloud.yaml
kubectl wait --for=condition=ready pod -l app=nextcloud -n ${NS} --timeout=300s

echo "=== Phase 4 Step 8: Copy app archives to fileserver ==="
FS_POD=$(kubectl get pod -l app=fileserver -n ${NS} -o jsonpath='{.items[0].metadata.name}')
kubectl cp airgapped/exports/app-archives/files/. "${NS}/${FS_POD}:/srv/apps/"

echo "=== Phase 4 Step 9: RustFS + bucket init ==="
kubectl apply -f airgapped/k8s/14-rustfs.yaml
kubectl wait --for=condition=ready pod -l app=rustfs -n ${NS} --timeout=180s
kubectl apply -f airgapped/k8s/15-rustfs-init-job.yaml
kubectl wait --for=condition=complete job/rustfs-init -n ${NS} --timeout=120s

echo "=== Phase 4 Step 10: Configure Nextcloud to use local App Store ==="
kubectl apply -f airgapped/k8s/11-configure-nextcloud-job.yaml
kubectl wait --for=condition=complete job/configure-nextcloud -n ${NS} --timeout=120s

echo "=== Phase 4 Step 11: Final pod status ==="
kubectl get pods -n ${NS}
kubectl get svc -n ${NS}

echo ""
echo "=== Access URLs ==="
echo "  App Store HTTPS : https://${NODE_IP}:30443"
echo "  App Store Admin : https://${NODE_IP}:30443/admin/"
echo "  File Server     : https://${NODE_IP}:30444/apps/"
echo "  Nextcloud       : http://${NODE_IP}:30082"
echo "  RustFS S3 API   : http://${NODE_IP}:30900"
echo "  RustFS Console  : http://${NODE_IP}:30901"
echo ""
echo "Validation:"
echo "  curl -sk https://${NODE_IP}:30443/health/"
echo "  curl -sk https://${NODE_IP}:30443/api/v1/platform/8/apps.json | python3 -m json.tool | head"
echo "  curl -sk https://${NODE_IP}:30444/apps/"
echo "  curl -s http://${NODE_IP}:30082/status.php"
echo "  curl -s http://${NODE_IP}:30900/minio/health/live"
```

---

## Appendix B — Secret Reference

| Secret Name | Keys | Notes |
|-------------|------|-------|
| `appstore-secrets` | `SECRET_KEY`, `DATABASE_PASSWORD` | SECRET_KEY must be 64 chars; DATABASE_PASSWORD must match postgres-secrets |
| `postgres-secrets` | `POSTGRES_USER`, `POSTGRES_DB`, `POSTGRES_PASSWORD` | POSTGRES_USER and POSTGRES_DB are `nextcloudappstore`; only POSTGRES_PASSWORD changes |
| `appstore-tls` | `tls.crt`, `tls.key`, `ca.crt` | Generated by `k8s/generate-certs.sh`; applied from `k8s/09-tls-secret.yaml` |
| `postgres-nc-secrets` | `POSTGRES_USER`, `POSTGRES_DB`, `POSTGRES_PASSWORD` | Lives in `12-postgres-nc.yaml`; user/db are `nextcloud` |
| `nextcloud-secrets` | `NEXTCLOUD_ADMIN_USER`, `NEXTCLOUD_ADMIN_PASSWORD`, `NEXTCLOUD_DB_PASSWORD` | Lives in `13-nextcloud.yaml`; NEXTCLOUD_DB_PASSWORD must match postgres-nc-secrets |
| `rustfs-secrets` | `RUSTFS_ACCESS_KEY`, `RUSTFS_SECRET_KEY` | Lives in `14-rustfs.yaml`; RUSTFS_SECRET_KEY min 8 chars |

**How to decode and re-encode a secret value:**

```bash
# Decode current value
kubectl get secret appstore-secrets -n nextcloud-appstore \
    -o jsonpath='{.data.DATABASE_PASSWORD}' | base64 -d; echo

# Encode a new value
echo -n "MyNewPassword" | base64

# Update in-place (replace the YAML data field, then apply)
kubectl apply -f airgapped/k8s/02-secrets.yaml

# Or use kubectl patch
kubectl patch secret appstore-secrets -n nextcloud-appstore \
    -p '{"data":{"DATABASE_PASSWORD":"'$(echo -n "MyNewPassword" | base64)'"}}'
```

After changing `DATABASE_PASSWORD`, you must also change `POSTGRES_PASSWORD` in `postgres-secrets` to match, then restart both postgres and appstore:

```bash
kubectl rollout restart deployment/postgres -n nextcloud-appstore
# Wait for postgres to come back up
kubectl wait --for=condition=ready pod -l app=postgres -n nextcloud-appstore --timeout=120s
kubectl rollout restart deployment/appstore -n nextcloud-appstore
```

---

## Appendix C — TLS Certificate Details

The `k8s/generate-certs.sh` script creates a three-tier PKI:

```
Root CA (10 years)
  └── Intermediate CA (5 years)
        └── Server Certificate (1 year)
```

`tls.crt` in the K8s secret is the full chain: `server.crt + intermediate-ca.crt + root-ca.crt`. This lets clients validate the chain without pre-installing the CA.

`ca.crt` is `intermediate-ca.crt + root-ca.crt`. Nextcloud mounts this at `/tmp/appstore-certs/root-ca.crt` and the configure job installs it into the OS trust store inside the Nextcloud container so PHP can verify the App Store TLS endpoint.

**Regenerating certificates (e.g., node IP changed, cert expired):**

```bash
# On the commercial host — set the correct IP or hostname
SERVER_CN="192.168.1.200" \
SERVER_ALT_NAMES="IP:192.168.1.200,DNS:appstore.local,DNS:localhost" \
bash k8s/generate-certs.sh

# Transfer k8s/09-tls-secret.yaml to air-gapped side

# On the cluster
kubectl apply -f k8s/09-tls-secret.yaml   # updates the secret in-place

# Restart nginx, fileserver, nextcloud to pick up new certs
kubectl rollout restart deployment/nginx deployment/fileserver deployment/nextcloud \
    -n nextcloud-appstore

# Re-run the configure job so Nextcloud reinstalls the new CA cert
kubectl delete job configure-nextcloud -n nextcloud-appstore --ignore-not-found
kubectl apply -f airgapped/k8s/11-configure-nextcloud-job.yaml
kubectl wait --for=condition=complete job/configure-nextcloud -n nextcloud-appstore --timeout=120s
```

**Trusting the Root CA on operator workstations (optional — removes browser warnings):**

```bash
# macOS
sudo security add-trusted-cert -d -r trustRoot \
    -k /Library/Keychains/System.keychain k8s/certs/root-ca.crt

# Linux (Debian/Ubuntu)
sudo cp k8s/certs/root-ca.crt /usr/local/share/ca-certificates/appstore-root-ca.crt
sudo update-ca-certificates

# Linux (RHEL/CentOS/Fedora)
sudo cp k8s/certs/root-ca.crt /etc/pki/ca-trust/source/anchors/appstore-root-ca.crt
sudo update-ca-trust extract
```

---

## Appendix D — Optional: Separate Nextcloud Deployment

The `09-nextcloud-test.yaml` manifest deploys a minimal standalone Nextcloud for testing the App Store integration. It does **not** use the production Nextcloud PostgreSQL — it uses SQLite by default.

```bash
# Apply only if you want a quick test Nextcloud with no database requirement
kubectl apply -f airgapped/k8s/09-nextcloud-test.yaml

# Wait for it
kubectl wait --for=condition=ready pod -l app=nextcloud-test \
    -n nextcloud-appstore --timeout=300s

# Access at http://{IP}:30081  (NOTE: shares NodePort with fileserver HTTP — conflict!)
```

> **Warning:** `09-nextcloud-test.yaml` assigns NodePort 30081 for HTTP, which conflicts with the fileserver's HTTP NodePort. Do not apply both at the same time. This manifest is intended for isolated testing only. Use `13-nextcloud.yaml` (NodePort 30082) for a production-grade Nextcloud deployment alongside the App Store.

---

## Appendix E — Firewall and Network Requirements

For the cluster nodes to be reachable from operator workstations and for Nextcloud to reach the App Store internally:

**Inbound on cluster nodes (from operator workstations / end users):**

| Port | Protocol | Purpose |
|------|----------|---------|
| 30080 | TCP | App Store HTTP (redirects to HTTPS) |
| 30443 | TCP | App Store HTTPS |
| 30081 | TCP | File Server HTTP |
| 30444 | TCP | File Server HTTPS |
| 30082 | TCP | Nextcloud HTTP |
| 30900 | TCP | RustFS S3 API |
| 30901 | TCP | RustFS Console |
| 6443 | TCP | Kubernetes API (from operator workstation only) |

**Cluster-internal (between pods — handled by CNI, normally no changes needed):**

| Port | Purpose |
|------|---------|
| 5432 | PostgreSQL (App Store) |
| 5432 | PostgreSQL (Nextcloud) |
| 8000 | uWSGI (appstore → nginx) |
| 9000 | RustFS S3 |
| 9001 | RustFS Console |

All inter-pod communication is within the `nextcloud-appstore` namespace on ClusterIP services and requires no external firewall changes.
