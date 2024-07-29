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
