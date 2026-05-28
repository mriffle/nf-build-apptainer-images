//
// Helpers for loading the `params.images` map from a Groovy/Nextflow-style
// config file or URL. Kept in lib/ (plain Groovy) so the imperative logic here
// — ConfigSlurper, URL/File handling, try/catch — is compiled normally and is
// not subject to the strict .nf language parser used for workflows/processes.
//
import java.nio.file.Path

class ImageConfig {

    // Convert a Nextflow Path or String into a java.io.File (or null).
    static File asFile(p) {
        if (p == null) return null
        (p instanceof Path) ? new File(p.toString()) : new File(p as String)
    }

    // Load params.images from a Groovy/Nextflow-style config file or URL.
    // If allowEmpty is true, a missing file/URL or absent params.images yields [:].
    static Map loadImagesMap(p, boolean allowEmpty = false) {
        if (p == null) {
            if (allowEmpty) return [:]
            throw new IllegalArgumentException("No config path/URL provided (null)")
        }

        URL url
        try {
            // Try URL first (supports http/https/file)
            url = new URL(p.toString())
        }
        catch (MalformedURLException e) {
            // Not a URL: treat as a local file
            def f = asFile(p)
            if (!f?.exists()) {
                if (allowEmpty) return [:]
                throw new FileNotFoundException("Config file not found: ${p}")
            }
            url = f.toURI().toURL()
        }

        def cfg = new ConfigSlurper().parse(url)
        def m = cfg?.params?.images

        if (m instanceof Map) return m as Map
        if (allowEmpty) return [:]
        throw new IllegalStateException("Expected params.images Map in ${p}")
    }
}
