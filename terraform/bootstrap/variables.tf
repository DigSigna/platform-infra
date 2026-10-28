variable "bucket_name" {
  description = "Nombre del Space (bucket S3-compatible) que va a guardar el state de Terraform de todos los ambientes"
  type        = string
}

variable "region" {
  description = "Región del Space (ej. nyc3). Define también el endpoint S3-compatible."
  type        = string
}
