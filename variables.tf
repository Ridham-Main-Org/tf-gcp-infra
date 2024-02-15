variable "project" {
  description = "GCP project ID"
  type        = string
}

variable "credentials_file" {
  description = "Path to the Google Cloud credentials file"
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "routing_mode" {
  description = "Routing mode for the VPC"
  default     = "REGIONAL"
}

variable "vpc" {

}

variable "ct" {

}