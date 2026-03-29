variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP region — Mumbai, closest to Pune"
  type        = string
  default     = "asia-south1"
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "asia-south1-a"
}

variable "machine_type" {
  description = "GCP machine type for all nodes. e2-medium = 2 vCPU / 4 GB RAM (dev/test). Use e2-standard-4 for production."
  type        = string
  default     = "e2-medium"
}

variable "disk_size" {
  description = "Boot disk size in GB for each node"
  type        = number
  default     = 60
}

variable "cluster_name" {
  description = "Elasticsearch cluster name"
  type        = string
  default     = "elk-cluster"
}

variable "es_heap_size" {
  description = "Elasticsearch JVM heap (Xms/Xmx). 1g is safe for e2-medium running multiple services."
  type        = string
  default     = "1g"
}

variable "logstash_heap_size" {
  description = "Logstash JVM heap size (on elk-node2)"
  type        = string
  default     = "512m"
}

variable "kafka_version" {
  description = "Apache Kafka version to install. Downloaded from archive.apache.org (not downloads.apache.org which only hosts the latest release)."
  type        = string
  default     = "3.7.0"
}

variable "kafka_scala_version" {
  description = "Scala version used in the Kafka binary package name"
  type        = string
  default     = "2.13"
}

variable "ssh_public_key_path" {
  description = "Path to your SSH public key (e.g. ~/.ssh/id_rsa.pub). Leave empty to skip."
  type        = string
  default     = ""
}

variable "ssh_user" {
  description = "SSH username injected into VM metadata"
  type        = string
  default     = "elk-admin"
}
