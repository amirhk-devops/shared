# Deoloy-Ai Pipeline

## Purpose

Builds a deployment package and deploys the AI application to the **Deployment environment**. The pipeline uses service images published to the internal Nexus Docker registry; it does not build the application service images on the Deployment server.

- Stage build server: `172.16.0.123`
- Deployment server: `172.16.0.124`
- Docker registry: `devops.chargoon.net:8083`

## High-level flow

1. **Prepare the deployment artifacts**
   - Uses the designated source branch (currently configured for `master`).
   - Runs the shared AI build template in deployment-package generation mode.
   - Produces a versioned deployment package containing deployment assets such as Compose definitions, configuration files, scripts, and required initial directory structure.

2. **Publish the deployment package**
   - Publishes the generated package as a separate deployment artifact.
   - The package is not the same thing as the service Docker images. It carries the files required to prepare and operate the deployment.

3. **Make service images available**
   - The service images are built by the Stage build process and published to Nexus.
   - The Deployment process uses the registry as its image source and pulls the required images from `devops.chargoon.net:8083`.
   - The service images include:
     - `ai/chargoon-ai-worker`
     - `ai/message-bus-api`
     - `ai/chargoon-ai-synchronization`
     - `ai/chargoon-ai-referral`
     - `ai/chargoon-ai-control-panel`
   - The deployment consumes the tags configured by the pipeline. The exact version-tag convention is defined by the pipeline and deployment scripts; `latest` is also published by the Stage image-publishing flow.

4. **Prepare the Deployment server**
   - Transfers and extracts the deployment package on `172.16.0.124`.
   - Uses the bootstrap and customer deployment scripts to prepare the runtime directory, configuration, and Compose deployment.
   - The package is extracted before its deployment files are used.

5. **Start or update the AI services**
   - Pulls the required service images from Nexus.
   - Starts or updates the services through Docker Compose.
   - The Deployment server runs the containers; it is not the image-build host.

6. **Publish and synchronize RAG documentation**
   - Retrieves the required documentation source.
   - Publishes the documentation to the AI runtime's RAG ingestion location.
   - Triggers the RAG synchronization process so the deployed AI environment can ingest the updated content.

## Main deployment locations

The pipeline and its deployment scripts use the following locations as part of the deployment workflow:

- `/opt/chargoon/ai`
- `/opt/chargoon/ai-deploy`
- `/mnt/appcs-didgahinstallation/AI-Installation`

The exact role of each directory is determined by the deployment scripts and package layout.

## Image lifecycle

```text
Build-Ai on Stage (172.16.0.123)
      |
      v
Build, tag and push service images
      |
      v
Nexus: devops.chargoon.net:8083
      |
      v
Deoloy-Ai on Deployment (172.16.0.124)
      |
      +--> Pull service images
      +--> Prepare deployment package
      +--> Start/update Docker Compose services
      +--> Update RAG documents
```

## Responsibility boundary

- **Build-Ai:** builds and publishes service images.
- **Nexus:** stores and distributes the published images.
- **Deoloy-Ai:** prepares the deployment package, pulls the published images, and runs the AI services on the Deployment server.
- The Deployment server does not compile or build the service images.
