// Modules
include { EXTRACT_DOCKER_IMAGES } from "../modules/extract_docker_images"
include { CHECK_BUILD_APPTAINER } from "../modules/check_build_apptainer"

workflow wf_apptainer {

    take:
        docker_image_file
        apptainer_cache_dir
        apptainer_tmp_dir
    
    main:

    def config = new ConfigSlurper().parse(docker_image_file.text)
    def dockerImages = config.params.images.values()
    docker_images = Channel.fromList(dockerImages)

    // Check and build Apptainer images
    CHECK_BUILD_APPTAINER(
        docker_images.flatten(),
        apptainer_cache_dir,
        apptainer_tmp_dir
    )

}
