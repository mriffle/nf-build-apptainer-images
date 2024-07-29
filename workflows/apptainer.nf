// Modules
include { EXTRACT_DOCKER_IMAGES } from "../modules/extract_docker_images"
include { CHECK_BUILD_APPTAINER } from "../modules/check_build_apptainer"

workflow wf_apptainer {

    take:
        docker_image_file_ch
        apptainer_cache_dir
        apptainer_tmp_dir
    
    main:

    // Extract Docker images
    EXTRACT_DOCKER_IMAGES(docker_image_file_ch)

    // Check and build Apptainer images
    CHECK_BUILD_APPTAINER(
        EXTRACT_DOCKER_IMAGES.out.docker_images.flatten(),
        apptainer_cache_dir,
        apptainer_tmp_dir
    )

}
