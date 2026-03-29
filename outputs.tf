output "vm_details" {
  description = "Internal and external IP addresses of all cluster nodes"
  value = {
    for name, instance in google_compute_instance.elk_nodes :
    name => {
      internal_ip = instance.network_interface[0].network_ip
      external_ip = instance.network_interface[0].access_config[0].nat_ip
      description = instance.description
    }
  }
}

output "kibana_url" {
  description = "Kibana web UI URL (elk-node3). Available ~5-8 min after VM start, after Phase 3 (passwords) are set."
  value       = "http://${google_compute_instance.elk_nodes["elk-node3"].network_interface[0].access_config[0].nat_ip}:5601"
}

output "elasticsearch_api_urls" {
  description = "Elasticsearch REST API endpoints. NOTE: uses http:// — only transport SSL is configured, not HTTP SSL."
  value = [
    for name, instance in google_compute_instance.elk_nodes :
    "http://${instance.network_interface[0].access_config[0].nat_ip}:9200"
  ]
}

output "kafka_bootstrap_servers" {
  description = "Kafka bootstrap server addresses (internal IPs, for use within the VPC)"
  value       = "192.168.1.101:9092,192.168.1.102:9092,192.168.1.103:9092"
}

output "ssh_commands" {
  description = "gcloud SSH commands to connect to each node"
  value = {
    for name, instance in google_compute_instance.elk_nodes :
    name => "gcloud compute ssh ${name} --zone=${var.zone} --project=${var.project_id}"
  }
}

output "cluster_health_check" {
  description = "Run this after Phase 3 (passwords set) to verify Elasticsearch cluster health. Uses http:// — transport TLS only."
  value       = "curl -u elastic:YOUR_PASSWORD http://${google_compute_instance.elk_nodes["elk-node1"].network_interface[0].access_config[0].nat_ip}:9200/_cluster/health?pretty"
}

output "startup_log_commands" {
  description = "Commands to tail startup logs on each node (run from your Mac)"
  value = {
    for name, instance in google_compute_instance.elk_nodes :
    name => "gcloud compute ssh ${name} --zone=${var.zone} --project=${var.project_id} -- 'sudo tail -f /var/log/elk-startup.log'"
  }
}

output "scp_cert_commands" {
  description = "gcloud scp commands to copy TLS cert from node1 to node2/node3 (Phase 2c). Run from your Mac after generating certs on node1."
  value = {
    pull_from_node1   = "gcloud compute scp elk-node1:/tmp/elastic-certificates.p12 /tmp/ --zone=${var.zone} --project=${var.project_id}"
    push_to_node2     = "gcloud compute scp /tmp/elastic-certificates.p12 elk-node2:/tmp/ --zone=${var.zone} --project=${var.project_id}"
    push_to_node3     = "gcloud compute scp /tmp/elastic-certificates.p12 elk-node3:/tmp/ --zone=${var.zone} --project=${var.project_id}"
  }
}

output "kafka_topic_create" {
  description = "Command to create the 'logs' Kafka topic after cluster is running (run on any node)"
  value       = "gcloud compute ssh elk-node1 --zone=${var.zone} --project=${var.project_id} -- '/opt/kafka/bin/kafka-topics.sh --create --topic logs --bootstrap-server 192.168.1.101:9092 --partitions 3 --replication-factor 3'"
}
