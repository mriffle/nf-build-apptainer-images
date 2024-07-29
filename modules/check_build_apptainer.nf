process CHECK_BUILD_APPTAINER {
    label 'process_low'

    input:
        val docker_image_location
        path apptainer_cache_directory
        path apptainer_tmp_directory

    script:
    apptainer_image_name = docker_image_location.replaceAll('/', '-').replaceAll(':', '-') + '.img'
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
        echo "Pulling ${docker_image_location} as Apptainer image"
        apptainer pull --name ${apptainer_image_name} docker://${docker_image_location} > /dev/null
        mv ${apptainer_image_name} ${apptainer_cache_directory}/
    else
        echo "Apptainer image ${apptainer_image_name} already exists in cache, skipping pull"
    fi
    """
}