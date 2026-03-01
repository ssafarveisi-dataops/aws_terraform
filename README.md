# Deploying an ML model as an AWS ECS service for POC purposes

## Workflow to deploy a model for a POC

1) Create a PR that adds two subdirectories with the same name under the `models` (source code, project dependencies, Dockerfile and the python version file) and `models_config` (POC configurations) directories. Use `-` as the separator in the name if needed (for example, experience-linker). The directory name must match the S3 prefix where the model artifacts are stored. For instance, if your model artifact `model.pth` is located at `s3://bucket/experience-linker/model.pth`, then both subdirectories should be named **experience-linker**. This ensures consistent naming across locations. At runtime, your application will have access to all objects with the prefix `s3://bucket/<subdirectory name>/`.

Please use the templates provided under `templates` to learn what you need to add to your subdirectories.

2) If your application requires a secret at runtime, it will be created before the PR is approved and merged. Refer to `templates/models_config/ml-model-1/config.yaml` for an example.

3) Once the PR is merged, the user can proceed with applying resources for the POC (see `.github/workflows/manage-resources.yaml`) before deploying the service on AWS (see `.github/workflows/deploy-task-definition.yaml`). For the first GitHub workflow, provide only the action (apply or destroy) and the subdirectory name (the POC model). For the second GitHub workflow, pass only the subdirectory name for which the service deployment should be executed.  


4) After the POC is complete, you can manually destroy the resources using `.github/workflows/manage-resources.yaml`. You can reapply the resources at any time.

> [!NOTE]
> The user will be notified via Slack about the success or failure of the GitHub workflows.

## Running POC

After a successful deployment, the user can begin model evaluations by sending requests to `https://api.dev.science.cognism.cloud/poc-deployment/<subdirectory name>/predict`. The Swagger UI will be available at the `/docs` endpoint.