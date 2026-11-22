# Update-knowledgeBase-Portal Pipeline

## Purpose

Updates the documentation supplied to the AI Portal's RAG ingestion process. It operates on the already-running AI Portal environment on the Deployment server.

This pipeline is a **documentation and RAG-content update**. It does not build Docker images, publish images to Nexus, pull service images, or deploy Docker Compose services.

- Deployment server: `172.16.0.124`
- Portal runtime: `/opt/chargoon/asa-portal`
- RAG ingestion directory: `/opt/chargoon/asa-portal/volumes/ai-worker/rag_ingest/docs`
- RAG API: `http://localhost:8110`

## High-level flow

1. **Get the documentation source**
   - Retrieves the `ZagrosHelp` repository from its `master` branch.

2. **Select the documentation content**
   - Finds and collects the documentation directories named `knowledgeBase`.
   - Also collects the additional correspondence documentation under `docs/Automation/مکاتبات`.

3. **Copy content to the Portal RAG ingestion directory**
   - Copies the selected content into:
     `/opt/chargoon/asa-portal/volumes/ai-worker/rag_ingest/docs`
   - This updates the source documents available to the Portal's RAG ingestion process.

4. **Trigger RAG synchronization**
   - Calls the Portal RAG API at `http://localhost:8110` to initiate synchronization/ingestion of the updated documents.

5. **Check synchronization-related information**
   - Retrieves source and volume information from the RAG service as part of the pipeline's follow-up operations.

## What this pipeline does not do

- Does not build AI service Docker images.
- Does not tag or push images to Nexus.
- Does not pull images from Nexus.
- Does not create or extract the AI deployment package.
- Does not start, stop, or update Docker Compose services.

## Position in the deployment architecture

```text
ZagrosHelp repository (master)
      |
      v
Select knowledgeBase directories
and docs/Automation/مکاتبات
      |
      v
Copy to Portal RAG ingestion directory
on Deployment server (172.16.0.124)
      |
      v
Call RAG API (localhost:8110)
      |
      v
RAG synchronization / ingestion
```

The pipeline assumes that the AI Portal runtime and its RAG service are already deployed and available. Its responsibility is limited to refreshing the documents consumed by that runtime.
