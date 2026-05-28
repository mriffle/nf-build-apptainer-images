process CHECK_BUILD_APPTAINER {
    label 'process_low'

    input:
        val docker_image_location
        val apptainer_cache_directory
        val apptainer_tmp_directory

    script:
    // Strip a leading 'docker://' if the config included one, so (a) the cached
    // filename matches Nextflow's SingularityCache.simpleName() (which the downstream
    // run uses to find the image) and (b) the pull URI below isn't doubled into
    // 'docker://docker://...'.
    def image_ref = docker_image_location.replaceFirst('^docker://', '')
    apptainer_image_name = image_ref.replaceAll('/', '-').replaceAll(':', '-') + '.img'
    """
    # Check if directories exist and have correct permissions
    if [ ! -d "${apptainer_cache_directory}" ]; then
        echo "ERROR: Apptainer cache directory does not exist: ${apptainer_cache_directory}" >&2
        exit 1
    fi

    if [ ! -w "${apptainer_cache_directory}" ]; then
        echo "ERROR: Insufficient privileges for Apptainer cache directory: ${apptainer_cache_directory}" >&2
        exit 1
    fi

    if [ ! -d "${apptainer_tmp_directory}" ]; then
        echo "ERROR: Apptainer temporary directory does not exist: ${apptainer_tmp_directory}" >&2
        exit 1
    fi

    if [ ! -w "${apptainer_tmp_directory}" ]; then
        echo "ERROR: Insufficient privileges for Apptainer temporary directory: ${apptainer_tmp_directory}" >&2
        exit 1
    fi

    export APPTAINER_TMPDIR="${apptainer_tmp_directory}"
    export APPTAINER_CACHEDIR="${apptainer_cache_directory}"

    if [ ! -f "${apptainer_cache_directory}/${apptainer_image_name}" ]; then
        echo "Pulling ${image_ref} as Apptainer image"
        apptainer pull --name ${apptainer_image_name} docker://${image_ref} > /dev/null
        mv ${apptainer_image_name} ${apptainer_cache_directory}/
    else
        echo "Apptainer image ${apptainer_image_name} already exists in cache, skipping pull"
    fi
    """

    stub:
    // Faithful, fast stand-in for the real script: same name transform, the same
    // directory checks, and the same cache-skip-vs-build branch — only the actual
    // 'apptainer pull' + 'mv' is replaced by 'touch'. This lets `-stub-run`
    // exercise the missing/unwritable-directory branches and the already-cached
    // skip path (no network, disk pulls, or Apptainer required).
    def image_ref = docker_image_location.replaceFirst('^docker://', '')
    apptainer_image_name = image_ref.replaceAll('/', '-').replaceAll(':', '-') + '.img'
    """
    if [ ! -d "${apptainer_cache_directory}" ]; then
        echo "ERROR: Apptainer cache directory does not exist: ${apptainer_cache_directory}" >&2
        exit 1
    fi

    if [ ! -w "${apptainer_cache_directory}" ]; then
        echo "ERROR: Insufficient privileges for Apptainer cache directory: ${apptainer_cache_directory}" >&2
        exit 1
    fi

    if [ ! -d "${apptainer_tmp_directory}" ]; then
        echo "ERROR: Apptainer temporary directory does not exist: ${apptainer_tmp_directory}" >&2
        exit 1
    fi

    if [ ! -w "${apptainer_tmp_directory}" ]; then
        echo "ERROR: Insufficient privileges for Apptainer temporary directory: ${apptainer_tmp_directory}" >&2
        exit 1
    fi

    if [ ! -f "${apptainer_cache_directory}/${apptainer_image_name}" ]; then
        echo "STUB: building placeholder ${apptainer_image_name} for ${image_ref}"
        touch "${apptainer_cache_directory}/${apptainer_image_name}"
    else
        echo "Apptainer image ${apptainer_image_name} already exists in cache, skipping pull"
    fi
    """
}