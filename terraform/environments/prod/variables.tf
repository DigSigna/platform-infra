variable "region" {
  description = "Región de DigitalOcean para la VPC y el cluster DOKS nuevos"
  type        = string
}

variable "tags" {
  description = "Tags de DigitalOcean aplicados a los recursos nuevos (VPC, DOKS)"
  type        = list(string)
  default     = ["platform-infra", "prod"]
}

# --- network ---

variable "vpc_name" {
  type = string
}

variable "vpc_ip_range" {
  description = "CIDR de la VPC nueva (ej. 10.20.0.0/20)"
  type        = string
}

# --- doks ---

variable "doks_name" {
  type = string
}

variable "doks_version" {
  description = "Versión exacta de Kubernetes, o vacío para usar la última de doks_version_prefix"
  type        = string
  default     = ""
}

variable "doks_version_prefix" {
  type    = string
  default = "1.30."
}

variable "doks_ha" {
  type    = bool
  default = false
}

variable "node_pool_name" {
  type    = string
  default = "default"
}

variable "node_size" {
  description = "Slug del tamaño de droplet para los nodos del pool (ej. s-2vcpu-4gb)"
  type        = string
}

variable "node_pool_min_nodes" {
  type    = number
  default = 1
}

variable "node_pool_max_nodes" {
  type    = number
  default = 3
}

# --- database (recurso existente, ver modules/database/README.md) ---

variable "db_name" {
  description = "Nombre real del database cluster existente (bitacoradigital-database-...)"
  type        = string
}

variable "db_engine" {
  type    = string
  default = "mysql"
}

variable "db_version" {
  description = "Versión real del engine (debe coincidir con el recurso existente)"
  type        = string
}

variable "db_size" {
  description = "Slug de tamaño real del cluster (debe coincidir con el recurso existente)"
  type        = string
}

variable "db_region" {
  description = "Región real donde vive hoy la base de datos (puede diferir de var.region)"
  type        = string
}

variable "db_node_count" {
  type = number
}

variable "db_private_network_uuid" {
  description = "UUID de la VPC donde vive HOY la base de datos (no la VPC nueva de este entorno)"
  type        = string
  default     = null
}

variable "db_tags" {
  type    = list(string)
  default = []
}
