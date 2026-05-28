# nf-build-apptainer-images
This workflow will access the Docker image definitions for a workflow (such as: https://raw.githubusercontent.com/mriffle/nf-skyline-dia-ms/main/container_images.config) and attempt to
build apptainer images for all Docker images listed in the file. 

## Background
When running on a system that requires using Apptainer instead of Docker, Nextflow will download and convert Docker images into Apptainer images. However, this conversion process
runs on the host system and can be long and CPU-intensive for large images. This is not desirable on the head nodes of computer clusters, where the Nextflow command is run. This
workflow, when run in advance of the desired workflow, will build any required Apptainer images using the cluster nodes (or where ever tasks are configured to run), instead of
on the host system.

## Recommended Usage
For Nextflow workflows that must be run as Apptainer images and that that have their Docker images defined in a central file
(such as https://raw.githubusercontent.com/mriffle/nf-skyline-dia-ms/main/container_images.config), it is recommended that this workflow be run
as part of a script before the desired workflow is run. For example:

1. Set the `docker_images_file` parameter to: "https://raw.githubusercontent.com/mriffle/nf-skyline-dia-ms/main/container_images.config", where `mriffle/nf-skyline-dia-ms` is the workflow being run
2. Run the nf-build-apptainer-images workflow
3. Run the `mriffle/nf-skyline-dia-ms` workflow (replace `mriffle/nf-skyline-dia-ms` with your workflow)

## Parameters

| Parameter | Required | Description |
| --- | --- | --- |
| `docker_images_file` | yes | Path or URL to a Nextflow/Groovy config that defines `params.images = [ name: 'registry/image:tag', ... ]`. This is typically the same `container_images.config` your target workflow already uses. |
| `apptainer_cache_dir` | yes | Directory where the built `.img` files are written. **Must be the same directory your downstream workflow uses as its Apptainer cache** (see below). |
| `apptainer_tmp_dir` | yes | Scratch directory used by Apptainer during image conversion. |
| `docker_images_override_file` | no | Optional Nextflow/Groovy config in the same `params.images = [ ... ]` format; entries here override entries from `docker_images_file` **by key**. Defaults to `images-override.config` in the launch directory if such a file is present. |
| `email` | no | If set, a completion notification is sent to this address. |

## Using the built images in your workflow

Each cached image is named using the same scheme Nextflow uses to look it up: the
image reference with `:` and `/` replaced by `-`, plus a `.img` suffix
(e.g. `quay.io/protio/diann:1.8.1` → `quay.io-protio-diann-1.8.1.img`).

For your downstream workflow to find and reuse these images — instead of
re-converting them on the head node — it **must use the same `apptainer_cache_dir`
as its Apptainer cache**. Set one of the following for the downstream run:

```groovy
// in the downstream workflow's Nextflow config
apptainer.cacheDir = '/path/to/your/apptainer_cache_dir'
```
```bash
# ...or as an environment variable
export NXF_APPTAINER_CACHEDIR=/path/to/your/apptainer_cache_dir
```

If these do not match, the downstream run will silently re-convert the images
itself — the exact situation this workflow exists to avoid.

## Notes

- **Requires Nextflow 25.10+ or 26+.** This pipeline uses the new (strict) Nextflow
  language. On Nextflow 26+ it is the default; on Nextflow 25 you must run with
  `NXF_SYNTAX_PARSER=v2` set in the environment.
- **Builds run one at a time** (`executor.queueSize = 1`) to avoid concurrent
  `apptainer pull` operations corrupting the shared cache, and to limit registry
  load and scratch usage. Raise `executor.queueSize` if you want parallel builds.
- `docker_images_file` and the override file are parsed with Groovy's
  `ConfigSlurper`, which **executes the file as code**. Only point them at sources
  you trust.
