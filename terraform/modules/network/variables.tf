variable "name" {
  description = "Nombre de la VPC"
  type        = string
}

variable "region" {
  description = "Región de DigitalOcean donde vive la VPC (ej. nyc3)"
  type        = string
}

variable "ip_range" {
  description = "Rango CIDR de la VPC (ej. 10.20.0.0/20). No debe superponerse con otras VPCs del mismo equipo."
  type        = string
}
