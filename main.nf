#!/usr/bin/env nextflow

nextflow.enable.dsl = 2


// Sub workflows
include { wf_apptainer } from "./workflows/apptainer"

//
// The main workflow
//
workflow {

    if (!params.docker_images_file) {
        error "ERROR: docker_images_file is not set"
    }

    // Validate apptainer_cache_dir
    validateDir(params.apptainer_cache_dir)

    // Validate apptainer_tmp_dir
    validateDir(params.apptainer_tmp_dir)

    wf_apptainer(params.docker_images_file, params.apptainer_cache_dir, params.apptainer_tmp_dir)

}

// check if the directory exists
def validateDir(param) {
    if (!param) {
        error "ERROR: ${param} is not set."
    }
    def dir = file(param)
    if (!dir.exists()) {
        error "ERROR: ${param} does not exist"
    }
    if (!dir.isDirectory()) {
        error "ERROR: ${param} is not a directory"
    }
    if (!dir.canWrite()) {
        error "ERROR: ${param} is not writable"
    }
}

//
// Used for email notifications
//
def email() {
    // Create the email text:
    def (subject, msg) = EmailTemplate.email(workflow, params)
    // Send the email:
    if (params.email) {
        sendMail(
            to: "$params.email",
            subject: subject,
            body: msg
        )
    }
}

//
// This is a dummy workflow for testing
//
workflow dummy {
    println "This is a workflow that doesn't do anything."
}

// Email notifications:
workflow.onComplete {
    try {
        email()
    } catch (Exception e) {
        println "Warning: Error sending completion email."
    }
}
