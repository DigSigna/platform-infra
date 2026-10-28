variable "name" {
  description = "Nombre del cluster DOKS"
  type        = string
}

variable "region" {
  description = "Región de DigitalOcean donde vive el cluster"
  type        = string
}

variable "vpc_uuid" {
  description = "UUID de la VPC (del módulo network) donde se despliega el cluster"
  type        = string
}

variable "k8s_version" {
  description = "Versión exacta de Kubernetes (ej. 1.30.4-do.0). Si se deja vacío, se usa la última versión disponible para k8s_version_prefix."
  type        = string
  default     = ""
}

variable "k8s_version_prefix" {
  description = "Prefijo de versión usado para resolver la última versión disponible cuando k8s_version está vacío (ej. '1.30.')"
  type        = string
  default     = "1.30."
}

variable "ha" {
  description = "Si el control plane corre en modo alta disponibilidad (costo adicional)"
  type        = bool
  default     = false
}

variable "auto_upgrade" {
  description = "Si el cluster se auto-actualiza dentro de la misma versión minor en la ventana de mantenimiento"
  type        = bool
  default     = true
}

variable "surge_upgrade" {
  description = "Si se usa surge upgrade (nodos extra temporales) al actualizar el node pool"
  type        = bool
  default     = true
}

variable "maintenance_day" {
  description = "Día de la ventana de mantenimiento (ej. 'sunday', o 'any')"
  type        = string
  default     = "sunday"
}

variable "maintenance_start_time" {
  description = "Hora UTC de inicio de la ventana de mantenimiento, formato HH:MM"
  type        = string
  default     = "04:00"
}

variable "node_pool_name" {
  description = "Nombre del node pool por defecto"
  type        = string
  default     = "default"
}

variable "node_size" {
  description = "Slug del tamaño de droplet para los nodos (ej. s-2vcpu-4gb)"
  type        = string
}

variable "node_pool_min_nodes" {
  description = "Mínimo de nodos del node pool (autoscale)"
  type        = number
  default     = 1
}

variable "node_pool_max_nodes" {
  description = "Máximo de nodos del node pool (autoscale)"
  type        = number
  default     = 3
}

variable "node_pool_labels" {
  description = "Labels de Kubernetes aplicados a los nodos del pool"
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags de DigitalOcean aplicados al cluster y al node pool"
  type        = list(string)
  default     = []
}
