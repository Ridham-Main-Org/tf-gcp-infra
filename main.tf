provider "google" {
  credentials = var.credentials_file
  project     = var.project
  region      = var.region
}

provider "google-beta" {
  credentials = var.credentials_file
  project     = var.project
  region      = var.region
}

resource "google_compute_network" "main_vpc_network" {
  count                           = var.ct
  name                            = "${var.vpc}-${count.index}"
  auto_create_subnetworks         = false
  routing_mode                    = var.routing_mode
  delete_default_routes_on_create = true
}

resource "google_compute_subnetwork" "webapp_subnet" {
  count                    = var.ct
  name                     = "${var.subnet1}-${count.index}"
  ip_cidr_range            = var.cidr-range1
  network                  = google_compute_network.main_vpc_network[count.index].self_link
  region                   = var.region
  private_ip_google_access = true
}

resource "google_compute_subnetwork" "db_subnet" {
  count         = var.ct
  name          = "${var.subnet2}-${count.index}"
  ip_cidr_range = var.cidr-range2
  network       = google_compute_network.main_vpc_network[count.index].self_link
  region        = var.region
}

resource "google_compute_route" "webapp_subnet_route" {
  count            = var.ct
  name             = "${var.route1}-${count.index}"
  dest_range       = var.dest-range
  network          = google_compute_network.main_vpc_network[count.index].self_link
  next_hop_gateway = var.internet-gateway
  priority         = 100
}

resource "google_compute_firewall" "my-allow-firewall" {
  count   = length(google_compute_network.main_vpc_network)
  name    = "${var.firewall_name}-allow-${count.index}"
  network = google_compute_network.main_vpc_network[count.index].name

  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = var.allowed_ports
  }

  priority = 900
  # source_tags = ["web"]
  direction     = var.direction
  source_ranges = [var.source_ranges]
  target_tags   = [var.instance_tag]
}

resource "google_compute_firewall" "my-deny-firewall" {
  count   = length(google_compute_network.main_vpc_network)
  name    = "${var.firewall_name}-deny-${count.index}"
  network = google_compute_network.main_vpc_network[count.index].name

  deny {
    protocol = "tcp"
  }

  priority = 1000
  # source_tags = ["web"]
  direction     = var.direction
  source_ranges = [var.source_ranges]
  target_tags   = [var.instance_tag]
}

resource "google_compute_instance" "vm-instance" {
  name         = var.instance-name
  machine_type = var.machine_type
  zone         = var.instance-zone

  tags = [var.instance_tag]

  boot_disk {
    initialize_params {
      image = "${var.project}/${var.custom-image-name}"
      size  = var.disk_size
      type  = var.disk_type
    }
  }

  network_interface {
    network    = google_compute_network.main_vpc_network[0].name
    subnetwork = google_compute_subnetwork.webapp_subnet[0].name

    access_config {
      // Ephemeral public IP
    }
  }
  metadata_startup_script = <<-EOT
#!/bin/bash
set -e

# Check if .env file already exists in /opt directory
if [ ! -f /opt/.env ]; then
    # Create .env file with database connection details
    echo "DB_HOST='${google_sql_database_instance.postgres.ip_address.0.ip_address}'" > /opt/.env
    echo "DB_NAME='${google_sql_database.database.name}'" >> /opt/.env
    echo "DB_USER='${google_sql_user.users.name}'" >> /opt/.env
    echo "DB_PORT=5432" >> /opt/.env
    echo "DB_PASSWORD='${google_sql_user.users.password}'" >> /opt/.env
    echo "TOPIC_NAME='projects/celestial-gecko-414117/topics/${google_pubsub_topic.verify_email.name}'" >> /opt/.env
fi

echo ".env file created with the following content:"
cat /opt/.env
sudo systemctl daemon-reload
sudo systemctl start gcp-centos8.service
sudo systemctl enable gcp-centos8.service

EOT

  service_account {
    email  = google_service_account.ops_service_acc.email
    scopes = ["cloud-platform"]
  }

}

resource "google_compute_region_instance_template" "default" {
  name        = "appserver-template"
  description = "This template is used to create app server instances."

  tags = [var.instance_tag]

  labels = {
    environment = "dev"
  }

  instance_description = "description assigned to instances"
  machine_type         = var.machine_type
  can_ip_forward       = false

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  // Create a new boot disk from an image
  disk {
    source_image      = "${var.project}/${var.custom-image-name}"
    auto_delete       = true
    boot              = true
    # // backup the disk every day
    # resource_policies = [google_compute_resource_policy.daily_backup.id]
  }

  network_interface {
    network = "default"
  }

  metadata = <<-EOT
#!/bin/bash
set -e

# Check if .env file already exists in /opt directory
if [ ! -f /opt/.env ]; then
    # Create .env file with database connection details
    echo "DB_HOST='${google_sql_database_instance.postgres.ip_address.0.ip_address}'" > /opt/.env
    echo "DB_NAME='${google_sql_database.database.name}'" >> /opt/.env
    echo "DB_USER='${google_sql_user.users.name}'" >> /opt/.env
    echo "DB_PORT=5432" >> /opt/.env
    echo "DB_PASSWORD='${google_sql_user.users.password}'" >> /opt/.env
    echo "TOPIC_NAME='projects/celestial-gecko-414117/topics/${google_pubsub_topic.verify_email.name}'" >> /opt/.env
fi

echo ".env file created with the following content:"
cat /opt/.env
sudo systemctl daemon-reload
sudo systemctl start gcp-centos8.service
sudo systemctl enable gcp-centos8.service

EOT
  service_account {
    email  = google_service_account.ops_service_acc.email
    scopes = ["cloud-platform"]
  }
}

resource "google_compute_health_check" "http-health-check" {
  name        = "http-health-check"
  description = "Health check via http"

  timeout_sec         = 5
  check_interval_sec  = 5
  healthy_threshold   = 3
  unhealthy_threshold = 5

  http_health_check {
    port_name          = "health-check-port"
    port = 3000
    # port_specification = 3000
    # host               = "1.2.3.4"
    request_path       = "/healthz"
    proxy_header       = "NONE"
    response           = "I AM HEALTHY"
  }
}

resource "google_compute_region_autoscaler" "foobar" {
  name   = "my-region-autoscaler"
  region = var.region
  target = google_compute_region_instance_group_manager.foobar.id

  autoscaling_policy {
    max_replicas    = 9
    min_replicas    = 3
    cooldown_period = 180

    cpu_utilization {
      target = 0.5
    }
  }
}

resource "google_compute_region_instance_group_manager" "appserver" {
  name = "appserver-igm"
  base_instance_name         = "app"
  region                     = var.region
  distribution_policy_zones  = ["us-west2-a", "us-west2-b","us-west2-c"]
  distribution_policy_target_shape = "BALANCED"
  version {
    instance_template = google_compute_region_instance_template.default.self_link_unique
  }

  all_instances_config {
    metadata = {
      metadata_key = "metadata_value"
    }
    labels = {
      label_key = "label_value"
    }
  }

  target_pools = [google_compute_target_pool.appserver.id]
  target_size  = 2

  named_port {
    name = "custom"
    port = 8888
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.http-health-check.id
    initial_delay_sec = 300
  }
}

resource "google_compute_target_pool" "default" {
  name = "target-instance-pool"

  # instances = [
  #   "us-central1-a/myinstance1",
  #   "us-central1-b/myinstance2",
  # ]

  health_checks = [
    google_compute_http_health_check.default.name,
  ]
}

resource "google_compute_global_address" "default" {
  provider      = google-beta
  project       = google_compute_network.main_vpc_network[0].project
  name          = "global-psconnect-ip"
  address_type  = var.address_type
  purpose       = "VPC_PEERING"
  network       = google_compute_network.main_vpc_network[0].id
  prefix_length = 16
}

resource "random_id" "db_name_suffix" {
  byte_length = 4
}

resource "google_service_networking_connection" "private_vpc_connection" {
  provider                = google-beta
  network                 = google_compute_network.main_vpc_network[0].id
  service                 = var.service_connection
  reserved_peering_ranges = [google_compute_global_address.default.name]
}

resource "google_sql_database_instance" "postgres" {
  name                = var.postgres_instance_name
  database_version    = var.db_version
  region              = var.region_sql_instance
  depends_on          = [google_service_networking_connection.private_vpc_connection]
  deletion_protection = false

  settings {
    tier              = "db-f1-micro"
    availability_type = var.routing_mode
    disk_type         = var.sql_instance_disk_type
    disk_size         = var.disk_size

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.main_vpc_network[0].id
    }
  }
}

resource "google_sql_database" "database" {
  name     = "webapp"
  instance = google_sql_database_instance.postgres.name
}

resource "random_password" "password" {
  length           = 16
  special          = true
  override_special = "_%@"
}
resource "google_sql_user" "users" {
  name     = "webapp"
  instance = google_sql_database_instance.postgres.name
  password = random_password.password.result
}

resource "google_service_account" "ops_service_acc" {
  account_id   = "ops-service-account-id-new"
  display_name = "Ops agent Service Account"
  project      = var.project
}

resource "google_project_iam_binding" "logging-role" {
  project = var.project
  role    = var.logging_role

  members = [
    "serviceAccount:${google_service_account.ops_service_acc.email}",
  ]
}

resource "google_project_iam_binding" "monitoring-metric-role" {
  project = var.project
  role    = var.monitoring_role

  members = [
    "serviceAccount:${google_service_account.ops_service_acc.email}",
  ]
}

resource "google_pubsub_topic_iam_binding" "pubsub_binding" {
  project = var.project
  role    = var.publisher_role
  topic   = google_pubsub_topic.verify_email.name
  members = [
    "serviceAccount:${google_service_account.ops_service_acc.email}"
  ]

  depends_on = [
    google_service_account.ops_service_acc,
    google_pubsub_topic.verify_email
  ]
}


resource "google_dns_record_set" "dns-a-record" {
  name         = var.dns_name
  type         = "A"
  ttl          = 300
  managed_zone = var.dns_zone_name
  rrdatas = [
    google_compute_instance.vm-instance.network_interface.0.access_config.0.nat_ip,
  ]
}

resource "google_pubsub_topic" "verify_email" {
  name                       = "verify_email"
  project                    = var.project
  message_retention_duration = var.topic_message_retentaion
}


resource "google_pubsub_subscription" "subscription" {
  name  = "my-subscription"
  topic = google_pubsub_topic.verify_email.id
  # 20 minutes
  message_retention_duration = var.subscription_message_retention
  retain_acked_messages      = true
  ack_deadline_seconds       = 600
  expiration_policy {
    ttl = "300000.5s"
  }
  retry_policy {
    minimum_backoff = "10s"
  }
  enable_message_ordering = false
}

data "archive_file" "default" {
  type        = "zip"
  output_path = var.bucket_output_path
  source_dir  = "./serverless/"
}
resource "google_storage_bucket" "my_bucket" {
  name          = "my-vcloud-bucket-${var.ct}"
  force_destroy = true
  location      = var.region
  project       = var.project
}

resource "google_storage_bucket_object" "object" {
  name       = "my-serverless-function.zip"
  bucket     = google_storage_bucket.my_bucket.name
  source     = data.archive_file.default.output_path # Add path to the zipped function source code
  depends_on = [google_storage_bucket.my_bucket]
}
resource "google_vpc_access_connector" "connector" {
  name          = "vpc-con"
  ip_cidr_range = var.vpc_connector_cidr_range
  region        = var.region
  network       = google_compute_network.main_vpc_network[0].self_link
  depends_on = [
    google_compute_network.main_vpc_network[0],
    google_sql_database.database
  ]
}

resource "google_service_account" "cloud_func_service_acc" {
  account_id   = "cloud-func-service-account-id"
  display_name = "cloud func invoker Service Account"
  project      = var.project
}
resource "google_cloudfunctions2_function" "default" {
  name     = "my-cloud-function"
  location = var.region

  build_config {
    runtime     = "nodejs20"
    entry_point = var.cloud_func_entry_point # Set the entry point
    source {
      storage_source {
        bucket = google_storage_bucket.my_bucket.name
        object = google_storage_bucket_object.object.name
      }
    }
  }

  service_config {
    max_instance_count = 1
    available_memory   = "256M"
    timeout_seconds    = var.timeout_sec
    ingress_settings   = "ALLOW_ALL"
    environment_variables = {
      DB_HOST         = "${google_sql_database_instance.postgres.ip_address.0.ip_address}"
      DB_NAME         = "${google_sql_database.database.name}"
      DB_USER         = "${google_sql_user.users.name}"
      DB_PORT         = "${var.db_port}"
      DB_PASSWORD     = "${google_sql_user.users.password}"
      MAILGUN_API_KEY = var.mailgun_api_key
    }
    service_account_email = google_service_account.cloud_func_service_acc.email
    # service_account_email         = google_service_account.ops_service_acc.email
    vpc_connector                 = google_vpc_access_connector.connector.name
    vpc_connector_egress_settings = "PRIVATE_RANGES_ONLY"
  }


  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    service_account_email = google_service_account.cloud_func_service_acc.email
    # service_account_email = google_service_account.ops_service_acc.email

    pubsub_topic = google_pubsub_topic.verify_email.id
    # retry_policy          = "RETRY_POLICY_RETRY"
  }

  depends_on = [
    google_storage_bucket.my_bucket,
    google_storage_bucket_object.object,
    google_pubsub_topic.verify_email,
    google_pubsub_topic_iam_binding.pubsub_binding,
    google_vpc_access_connector.connector,
    google_compute_global_address.default
  ]
}

resource "google_cloud_run_service_iam_binding" "cloudfunction_binding" {
  project  = google_cloudfunctions2_function.default.project
  location = google_cloudfunctions2_function.default.location
  service  = google_cloudfunctions2_function.default.name
  role     = var.invoker_role
  members = [
    "serviceAccount:${google_service_account.cloud_func_service_acc.email}"
    # "serviceAccount:${google_service_account.ops_service_acc.email}"
  ]

  depends_on = [
    # google_service_account.ops_service_acc,
    google_service_account.cloud_func_service_acc,
    google_cloudfunctions2_function.default
  ]
}

output "function_uri" {
  value = google_cloudfunctions2_function.default.service_config[0].uri
}
