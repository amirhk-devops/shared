# Build-Ai Pipeline

## Purpose

Builds the AI application images in the **Stage environment**, publishes the resulting service images to the internal Nexus Docker registry, and deploys the built version to the Stage runtime.

- Stage server: `172.16.0.123`
- Docker registry: `devops.chargoon.net:8083`

This pipeline is the build-and-publish path. It is not the customer deployment pipeline.

## High-level flow

1. **Get source code**
   - Retrieves the AI application source from the branch selected for the pipeline run.
   - Retrieves the documentation source used by the RAG knowledge-base update.

2. **Build service images on Stage**
   - Builds the Docker images for the AI services from the selected source revision.
   - The service image set includes:
     - `ai/chargoon-ai-worker`
     - `ai/message-bus-api`
     - `ai/chargoon-ai-synchronization`
     - `ai/chargoon-ai-referral`
     - `ai/chargoon-ai-control-panel`

3. **Tag and publish images to Nexus**
   - Applies the pipeline's version-specific tags to the newly built images.
   - Also applies the `latest` tag.
   - Pushes the tagged service images to the central Nexus Docker registry at `devops.chargoon.net:8083`.
   - Nexus is the shared image distribution point; it is separate from both the Stage runtime and the Deployment server.

4. **Deploy the build to Stage**
   - Deploys the selected build to the Stage runtime using the Stage deployment script.
   - Starts or updates the relevant Compose services so the Stage environment runs the built images.

5. **Update the Stage RAG documents**
   - Retrieves the required documentation from the documentation repository.
   - Copies the applicable documentation into the RAG ingestion area, excluding the separately managed `knowledgeBase` content where applicable to this pipeline.
   - Triggers the RAG synchronization process.

## Image lifecycle

```text
AI source branch
      |
      v
Build images on Stage (172.16.0.123)
      |
      v
Apply version tags and latest
      |
      v
Push service images to Nexus
(devops.chargoon.net:8083)
      |
      +------> Stage deployment runs the selected build
      |
      +------> Deployment pipelines can pull published images
```

The service images and the deployment package are different artifacts. Service images contain the runnable application services. The deployment package is used by the customer deployment process to distribute Compose files, configuration, scripts, and initial directory structure.

## Responsibility boundary

- **Build-Ai:** source retrieval, service image build, image tagging, publication to Nexus, Stage deployment, and Stage RAG document update.
- **Nexus:** central storage and distribution of published Docker images.
- **Deploy-Ai / Deploy-Ai-Portal:** consume images from Nexus and deploy them to their respective Deployment-server locations.
- **Update-knowledgeBase-Portal:** updates the Portal RAG documents without rebuilding or publishing service images.
