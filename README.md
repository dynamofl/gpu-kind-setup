## GPU kind bootstrap

This directory contains a self‑contained helper script for spinning up a GPU-enabled `kind` cluster using NVIDIA's `nvkind`.

### Contents

| File | Purpose |
|------|---------|
| `bootstrap.sh` | Main automation script (cluster create → device plugin → smoke test). |
| `nvkind-ingress.yaml` | `kind` cluster configuration template consumed by `nvkind`. |

### Prerequisites

Install the dependencies first (Docker, kind, kubectl, Helm, Go, Make, jq, nvkind). The root `bootstrap/install-deps.sh` in this repo can do this for you.

Your host must expose NVIDIA GPUs and have the driver + CUDA toolkit stack installed. If Docker is not already configured for the NVIDIA runtime, run the script with `CONFIGURE_TOOLKIT=true`.

### Usage

```bash
# optional: tweak defaults
export CLUSTER_NAME=kind-gpu
export CONFIGURE_TOOLKIT=true      # only needed the first time on a new host

bootstrap/bootstrap.sh
```

The script will:

1. Clone/build `nvkind` (or reuse an existing checkout)
2. Recreate the named cluster via `nvkind` using the provided template
3. Install the NVIDIA device plugin with `runtimeClassName=nvidia`
4. Verify that GPU allocatable resources are visible
5. Run a simple `nvidia-smi` smoke test pod (skip via `SKIP_SMOKE_TEST=true`)

Key environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLUSTER_NAME` | `kind-gpu` | Name of the kind cluster |
| `NVKIND_DIR` | `../nvkind` | Location of the nvkind checkout/binary |
| `TEMPLATE_PATH` | `nvkind-ingress.yaml` | Cluster template passed to `nvkind` |
| `DELETE_EXISTING` | `true` | Whether to delete an existing cluster with the same name |
| `CONFIGURE_TOOLKIT` | `false` | Configure NVIDIA container toolkit + restart Docker |
| `SKIP_SMOKE_TEST` | `false` | Skip the CUDA smoke test pod |

Once the script prints `Cluster '<name>' is ready for GPU workloads`, you can start installing your application stack.
