// Modules
include { CHECK_BUILD_APPTAINER } from "../modules/check_build_apptainer"

workflow wf_apptainer {

    take:
    docker_image_file               // path or val
    docker_images_override_file     // optional: path or val; may be null or non-existent
    apptainer_cache_dir
    apptainer_tmp_dir

    main:

    // Convert whatever (Path/String) to a java.io.File
    def asFile = { p ->
        if (p == null) return null
        (p instanceof Path) ? new File(p.toString()) : new File(p as String)
    }

    // Load params.images from a Groovy/Nextflow-style config; allowEmpty => return [:] if missing
    def loadImagesMap = { p, boolean allowEmpty = false ->
        def f = asFile(p)
        def cfg = new ConfigSlurper().parse(f.toURI().toURL())
        def m = cfg?.params?.images
        if (m instanceof Map) return (Map)m
        if (allowEmpty) return [:]
        throw new IllegalStateException("Expected params.images Map in ${f?.absolutePath}")
    }

    // Base images map (strict)
    base_map_ch = Channel
        .of(docker_image_file)
        .map { loadImagesMap(it, false) }

    // Override images map (optional; missing file OR missing params.images => empty map)
    override_map_ch = Channel
        .of(docker_images_override_file)
        .filter { it != null }
        .filter { p -> asFile(p).exists() }
        .map    { loadImagesMap(it, true) }
        .defaultIfEmpty([:])   // <-- IMPORTANT: empty Map, not a list of a map

    // Merge: override wins for overlapping keys
    merged_map_ch = base_map_ch
        .combine(override_map_ch)
        .map { base, over -> base + over }

    // Stream one image definition per item
    docker_images_ch = merged_map_ch
        .map { it.values() }
        .flatten()

    // Ensure value channels for dirs
    cache_ch = Channel.value(apptainer_cache_dir)
    tmp_ch   = Channel.value(apptainer_tmp_dir)

    // Run module
    CHECK_BUILD_APPTAINER(
        docker_images_ch,
        cache_ch,
        tmp_ch
    )
}
