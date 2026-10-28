variable "name" {
  description = "Nombre del database cluster tal como existe hoy en DigitalOcean (ej. bitacoradigital-database-...). Debe coincidir exactamente con el recurso real: Terraform no lo usa para crear, sino para importar."
  type        = string
}

variable "engine" {
  description = "Motor de la base de datos. Debe ser 'mysql' para este recurso ya existente."
  type        = string
  default     = "mysql"
}

variable "engine_version" {
  description = "Versión del engine tal como está hoy en el recurso real (ej. '8'). Debe coincidir exactamente — un mismatch fuerza un diff en el próximo plan. Se llama engine_version (no 'version') porque 'version' es un argumento reservado en los bloques module de Terraform."
  type        = string
}

variable "size" {
  description = "Slug del tamaño del cluster tal como está hoy (ej. db-s-1vcpu-2gb). Debe coincidir exactamente con el recurso real."
  type        = string
}

variable "region" {
  description = "Región donde vive hoy la base de datos. Puede ser distinta de la región del VPC/DOKS nuevos — esta base NO se migra de región/red como parte de este módulo."
  type        = string
}

variable "node_count" {
  description = "Cantidad de nodos del cluster tal como está hoy (1 para standalone, 2-3 si tiene standby/réplicas)."
  type        = number
}

variable "private_network_uuid" {
  description = "UUID de la VPC donde vive HOY la base de datos (no la VPC nueva del módulo network, salvo que se decida explícitamente migrarla). Dejar null si está en la VPC default de la cuenta/región."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags de DigitalOcean aplicados al cluster, tal como están hoy en el recurso real"
  type        = list(string)
  default     = []
}
