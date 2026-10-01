# Container Image Documentation

## Base Image
Base image used for building the pipeline container:
`mambaorg/micromamba:ubuntu24.04` (from https://github.com/mamba-org/micromamba-docker)

## Container Registry Digest
The image was built, published to Docker Hub, and pulled via Apptainer using:
`fardinatabassum/variant-call@sha256:3ee02d026e15eaccadad9d182f2189e1e4e574e03d7bb81f6732e68c92301074`

## Pinned Tool Versions
The container environment provides the following 7 tool versions matching the course environment:

- fastqc: 0.12.1
- trimmomatic: 0.39
- bwa: 0.7.17-r1188
- samtools: 1.20
- gatk4: 4.5.0.0
- bcftools: 1.20
- multiqc: 1.21