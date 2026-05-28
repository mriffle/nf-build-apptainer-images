// Modules
include { CHECK_BUILD_APPTAINER } from "../modules/check_build_apptainer"

workflow wf_apptainer {

    take:
    docker_image_file               // required: path or string to a Groovy/Nextflow config defining params.images
    docker_images_override_file     // optional: path or string; may be null or absent
    apptainer_cache_dir             // e.g., '/scratch/apptainer/cache'
    apptainer_tmp_dir               // e.g., '/scratch/apptainer/tmp'

    main:

    // Load the base images map (strict: the file must define params.images) and
    // an optional override map (missing/empty -> [:]); override keys win. The
    // config-loading logic lives in lib/ImageConfig.groovy so it stays plain
    // Groovy -- the strict .nf parser only governs this workflow script.
    def base_map     = ImageConfig.loadImagesMap(docker_image_file, false)
    def overrideFile = ImageConfig.asFile(docker_images_override_file)
    def override_map = (overrideFile && overrideFile.exists()) ? ImageConfig.loadImagesMap(overrideFile, true) : [:]
    def merged_map   = base_map + override_map

    // Guard: an empty merge means the base config lacked or emptied params.images
    // (ConfigSlurper coerces a missing key to an empty map, so this also catches
    // typos / wrong files). Fail loudly instead of silently building nothing --
    // otherwise the downstream run would re-convert images on the head node.
    if (!merged_map) {
        def msg = "ERROR: No images to build. '${docker_image_file}'"
        if (overrideFile && overrideFile.exists()) {
            msg += " (with override '${overrideFile}')"
        }
        msg += " yielded an empty 'params.images' map. Check the path/URL and that the file"
        msg += " defines params.images = [ name: 'registry/image:tag', ... ]."
        error msg
    }

    // Emit one Docker image URI per item.
    docker_images_ch = Channel.fromList(merged_map.values().toList()).flatten()

    CHECK_BUILD_APPTAINER(
        docker_images_ch,
        Channel.value(apptainer_cache_dir),
        Channel.value(apptainer_tmp_dir)
    )
}
