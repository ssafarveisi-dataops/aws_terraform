variable "openapi_key" {
  sensitive   = true
  type        = string
  description = "Dummy OpenAPI key used by the container at runtime"
}
