process EXTRACT_DOCKER_IMAGES {
    label 'process_low'

    input:
        path docker_image_file

    output:
        emit: docker_images

    exec:
    def config = new ConfigSlurper().parse(docker_image_file.text)
    def dockerImages = config.params.images.values()
    docker_images = Channel.fromList(dockerImages)
}