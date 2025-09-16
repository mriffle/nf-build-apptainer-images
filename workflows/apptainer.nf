// Modules
include { CHECK_BUILD_APPTAINER } from "../modules/check_build_apptainer"

workflow wf_apptainer {

    take:
    docker_image_file
    docker_images_override_file
    apptainer_cache_dir
    apptainer_tmp_dir

    main:

    // Loader that can return empty map if images missing (use for override)
    def loadImagesMap = { p, boolean allowEmpty = false ->
        def f = (p instanceof Path) ? new File(p.toString()) : new File(p as String)
        def cfg = new ConfigSlurper().parse(f.toURI().toURL())
        def m = cfg?.params?.images
        if (m instanceof Map) return (Map)m
        if (allowEmpty)       return [:]
        // base file should define params.images; keep this strict
        throw new IllegalStateException("Expected params.images Map in ${f.absolutePath}")
    }

    // Base images (required)
    base_map_ch = Channel
        .of(docker_image_file)
        .map { loadImagesMap(it, false) }

    // Override images (optional; missing or absent images => empty map)
    override_map_ch = Channel
        .of(docker_images_override_file)
        .filter { it != null }
        .filter { p -> new File((p instanceof Path) ? p.toString() : (p as String)).exists() }
        .map    { loadImagesMap(it, true) }
        .defaultIfEmpty([:])

    // Merge: override wins
    merged_map_ch = base_map_ch
        .combine(override_map_ch)
        .map { base, over -> base + over }

    // One image per item
    docker_images_ch = merged_map_ch.map { it.values() }.flatten()

    CHECK_BUILD_APPTAINER(
        docker_images_ch,
        Channel.value(apptainer_cache_dir),
        Channel.value(apptainer_tmp_dir)
    )
}
