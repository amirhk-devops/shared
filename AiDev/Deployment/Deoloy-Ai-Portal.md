# Deoloy-Ai-Portal Pipeline

## Purpose

Builds the AI deployment package and deploys the AI application to the **AI Portal runtime** in the Deployment environment. Like the standard AI deployment pipeline, it consumes service images published to Nexus rather than building those service images on the Deployment server.

- Stage build server: `172.16.0.123`
- Deployment server: `172.16.0.124`
- Docker registry: `devops.chargoon.net:8083`

## High-level flow

1. **Prepare deployment artifacts**
   - Uses the configured source branch (currently `master`).
   - Runs the shared AI build template with deployment-package generation enabled.
   - Generates a deployment package containing the Compose definitions, configuration, scripts, and required initial directory structure.

2. **Publish the deployment package**
   - Publishes the generated package for the deployment stage.
   - This package is separate from the service Docker images. It contains the files needed to prepare and operate the Portal deployment.

3. **Use the service images published to Nexus**
   - Service images are built in the Stage environment by the build pipeline and pushed to `devops.chargoon.net:8083`.
   - This pipeline deploys by pulling the required images from Nexus.
   - The service image set includes:
     - `ai/chargoon-ai-worker`
     - `ai/message-bus-api`
     - `ai/chargoon-ai-synchronization`
     - `ai/chargoon-ai-referral`
     - `ai/chargoon-ai-control-panel`
   - The pipeline uses the image tags configured in its deployment process. The exact version-tag convention belongs to the pipeline and deployment scripts.

4. **Prepare the Portal deployment**
   - Transfers and extracts the deployment package on `172.16.0.124`.
   - Uses the deployment bootstrap and customer deployment scripts to prepare the Portal runtime and its Compose configuration.
   - The package is extracted and its files are then used by the deployment process.

5. **Start or update Portal services**
   - Pulls the required service images from Nexus.
   - Starts or updates the AI Portal services through Docker Compose.
   - The Deployment server runs the containers; it does not build the service images.

## Main deployment locations

The pipeline and deployment scripts use the following locations:

- `/opt/chargoon`
- `/opt/chargoon/asa-portal`
- `/opt/chargoon/asa-portal-ai-deploy`
- `/mnt/appcs-didgahinstallation/AI-Installation`

These locations serve different parts of the deployment and package workflow; their exact use is defined by the deployment scripts.

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
Deoloy-Ai-Portal on Deployment (172.16.0.124)
      |
      +--> Pull service images
      +--> Prepare and extract deployment package
      +--> Start/update Portal Docker Compose services
```

## Difference from Deoloy-Ai

Both deployment pipelines consume service images from Nexus and prepare a deployment package. Their target runtime and deployment locations differ:

- **Deoloy-Ai:** deploys the standard AI environment.
- **Deoloy-Ai-Portal:** deploys the AI services in the `asa-portal` environment.

This Portal pipeline does not perform the separate ZagrosHelp/RAG documentation publishing stage described in the standard deployment pipeline.

## Responsibility boundary

- **Build-Ai:** builds and publishes service images.
- **Nexus:** central image registry.
- **Deoloy-Ai-Portal:** prepares the Portal deployment, pulls images, and runs the Portal services.
- The Deployment server does not build the service images.
