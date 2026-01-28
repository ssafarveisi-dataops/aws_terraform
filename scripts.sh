# Check if a service is ACTIVE in an ECS cluster

# ECS cluster name
cluster_name=$1
# ECS service name
service_name=$2

SERVICE_STATUS=$(
  aws ecs describe-services \
    --cluster $cluster_name \
    --services $service_name \
    | jq --raw-output 'select(.services[].status != null ) | .services[].status'
)

if [ "$SERVICE_STATUS" = "ACTIVE" ]; then
    echo "Service is Active"
else
    echo "Service does not exist"
fi