// Modules
include { EXTRACT_DOCKER_IMAGES } from "../modules/extract_docker_images"
include { CHECK_BUILD_APPTAINER } from "../modules/check_build_apptainer"

workflow wf_apptainer {

    take:
        docker_image_file
        apptainer_cache_dir
        apptainer_tmp_dir
    
    main:

    // Create a channel from the docker_image_file path
    docker_image_file_ch = Channel.fromPath(docker_image_file)

    // Extract Docker images
    docker_images = docker_image_file_ch.flatMap { file ->
        def config = new ConfigSlurper().parse(file.text)
        config.params.images.values()
    }

    // Check and build Apptainer images
    CHECK_BUILD_APPTAINER(
        docker_images.flatten(),
        apptainer_cache_dir,
        apptainer_tmp_dir
    )

}
