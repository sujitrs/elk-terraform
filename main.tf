terraform {
  required_version = ">= 1.3"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# ─────────────────────────────────────────────
# LOCALS — node map + shared template vars
# ─────────────────────────────────────────────

locals {
  nodes = {
    "elk-node1" = {
      ip          = "192.168.1.101"
      broker_id   = 1
      zk_myid     = 1
      description = "Elasticsearch master+data | Zookeeper | Kafka Broker 1"
    }
    "elk-node2" = {
      ip          = "192.168.1.102"
      broker_id   = 2
      zk_myid     = 2
      description = "Elasticsearch data | Kafka Broker 2 | Logstash"
    }
    "elk-node3" = {
      ip          = "192.168.1.103"
      broker_id   = 3
      zk_myid     = 3
      description = "Elasticsearch data | Kafka Broker 3 | Kibana"
    }
  }

  # Variables passed to every startup script template
  common_vars = {
    cluster_name        = var.cluster_name
    es_heap_size        = var.es_heap_size
    logstash_heap_size  = var.logstash_heap_size
    kafka_version       = var.kafka_version
    kafka_scala_version = var.kafka_scala_version
    node1_ip            = "192.168.1.101"
    node2_ip            = "192.168.1.102"
    node3_ip            = "192.168.1.103"
  }

  ssh_metadata = var.ssh_public_key_path != "" ? {
    ssh-keys = "${var.ssh_user}:${file(var.ssh_public_key_path)}"
  } : {}
}

# ─────────────────────────────────────────────
# VPC & SUBNET
# ─────────────────────────────────────────────

resource "google_compute_network" "elk_vpc" {
  name                    = "elk-kafka-vpc"
  auto_create_subnetworks = false
  description             = "VPC for ELK + Kafka cluster"
}

resource "google_compute_subnetwork" "elk_subnet" {
  name          = "elk-kafka-subnet"
  ip_cidr_range = "192.168.1.0/24"
  region        = var.region
  network       = google_compute_network.elk_vpc.id
}

# ─────────────────────────────────────────────
# FIREWALL RULES
# ─────────────────────────────────────────────

# All traffic between cluster nodes (internal subnet only)
resource "google_compute_firewall" "internal" {
  name        = "elk-kafka-internal"
  network     = google_compute_network.elk_vpc.name
  description = "Allow all TCP/UDP/ICMP between cluster nodes"

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }

  source_ranges = ["192.168.1.0/24"]
  target_tags   = ["elk-kafka-cluster"]
}

# SSH — public access (restrict source IP in production)
resource "google_compute_firewall" "ssh" {
  name        = "elk-kafka-ssh"
  network     = google_compute_network.elk_vpc.name
  description = "SSH access"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["elk-kafka-cluster"]
}

# Kibana UI — public access (on elk-node3)
resource "google_compute_firewall" "kibana" {
  name        = "elk-kafka-kibana"
  network     = google_compute_network.elk_vpc.name
  description = "Kibana web UI (port 5601)"

  allow {
    protocol = "tcp"
    ports    = ["5601"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["elk-kafka-cluster"]
}

# Logstash Beats input — public access (on elk-node2)
resource "google_compute_firewall" "logstash" {
  name        = "elk-kafka-logstash"
  network     = google_compute_network.elk_vpc.name
  description = "Logstash Beats input (port 5044)"

  allow {
    protocol = "tcp"
    ports    = ["5044"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["elk-kafka-cluster"]
}

# ─────────────────────────────────────────────
# VM INSTANCES  (3 × e2-medium, Rocky Linux 9)
# ─────────────────────────────────────────────

resource "google_compute_instance" "elk_nodes" {
  for_each     = local.nodes
  name         = each.key
  machine_type = var.machine_type
  zone         = var.zone
  description  = each.value.description

  tags   = ["elk-kafka-cluster"]
  labels = { cluster = "elk-kafka" }

  boot_disk {
    initialize_params {
      image = "rocky-linux-cloud/rocky-linux-9"
      size  = var.disk_size
      type  = "pd-ssd"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.elk_subnet.id
    network_ip = each.value.ip   # Static internal IP

    access_config {
      # Ephemeral public IP — remove this block for private-only deployment
    }
  }

  metadata = merge(local.ssh_metadata, {
    serial-port-enable = "TRUE"

    startup-script = templatefile(
      "${path.module}/scripts/${each.key}.sh.tpl",
      merge(local.common_vars, {
        node_name = each.key
        node_ip   = each.value.ip
        broker_id = each.value.broker_id
        zk_myid   = each.value.zk_myid
      })
    )
  })

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }
}
