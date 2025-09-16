// Modules
include { CHECK_BUILD_APPTAINER } from "../modules/check_build_apptainer"

workflow wf_apptainer {

    take:
    docker_image_file               // required: path or string to Groovy/Nextflow config
    docker_images_override_file     // optional: path or string; may be null or absent
    apptainer_cache_dir             // e.g., '/scratch/apptainer/cache'
    apptainer_tmp_dir               // e.g., '/scratch/apptainer/tmp'

    main:

    // -- helpers -------------------------------------------------------------

    // Convert Nextflow Path or String into java.io.File (or null)
    def asFile = { p ->
        if (p == null) return null
        (p instanceof Path) ? new File(p.toString()) : new File(p as String)
    }

    // Load params.images from a Groovy/Nextflow-style config file.
    // If allowEmpty=true and params.images missing, return empty map.
    def loadImagesMap = { p, boolean allowEmpty = false ->
        def f = asFile(p)
        assert f && f.exists() : "Config file not found: ${p}"
        def cfg = new ConfigSlurper().parse(f.toURI().toURL())
        def m = cfg?.params?.images
        if (m instanceof Map) return (Map)m
        if (allowEmpty) return [:]
        throw new IllegalStateException("Expected params.images Map in ${f.absolutePath}")
    }

    // -- base config (strict) -----------------------------------------------

    base_map_ch = Channel
        .of(docker_image_file)
        .map { loadImagesMap(it, false) }   // must contain params.images map

    // -- override config (optional) -----------------------------------------

    def overrideFile = asFile(docker_images_override_file)

    override_map_ch = (overrideFile && overrideFile.exists())
        ? Channel.of(loadImagesMap(overrideFile, true))  // allowEmpty -> [:] if images missing
        : Channel.of([:])                                // fallback empty map if no file

    // -- merge & flatten -----------------------------------------------------

    // Merge maps: keys in override replace base
    merged_map_ch = base_map_ch
        .combine(override_map_ch)
        .map { base, over -> base + over }

    // Emit one image definition per item (values of the merged map)
    docker_images_ch = merged_map_ch
        .map { it.values() }
        .flatten()

    // Ensure value channels for dirs
    cache_ch = Channel.value(apptainer_cache_dir)
    tmp_ch   = Channel.value(apptainer_tmp_dir)

    // -- module call ---------------------------------------------------------

    CHECK_BUILD_APPTAINER(
        docker_images_ch,   // one image per item
        cache_ch,
        tmp_ch
    )

    // If the caller needs outputs, you can emit from the module like:
    // emit:
    //   built = CHECK_BUILD_APPTAINER.out
}
