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

# resource "google_compute_firewall" "my-allow-firewall" {
#   count   = length(google_compute_network.main_vpc_network)
#   name    = "${var.firewall_name}-allow-${count.index}"
#   network = google_compute_network.main_vpc_network[count.index].name

#   allow {
#     protocol = "tcp"
#     ports    = var.allowed_ports
#   }

#   priority = 900
#   direction     = var.direction
#   source_ranges = [var.source_ranges]
#   target_tags   = ["load-balanced-backend"]
# }

resource "google_compute_firewall" "my-deny-firewall" {
  count   = length(google_compute_network.main_vpc_network)
  name    = "${var.firewall_name}-deny-${count.index}"
  network = google_compute_network.main_vpc_network[count.index].name

  deny {
    protocol = "tcp"
  }
  direction     = var.direction
  source_ranges = [var.source_ranges]
  target_tags   = [var.instance_tag]
}
##################################################################################################
#Instance-template, autoscaling
resource "google_compute_region_instance_template" "template" {
  name        = "my-template"
  description = "This template is used to create app server instances."

  tags                 = [var.instance_tag]
  instance_description = "description assigned to instances"
  machine_type         = var.machine_type

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }
  disk {
    source_image = "${var.project}/${var.custom-image-name}"
    auto_delete  = true
    boot         = true
    device_name  = "persistent-disk-0"
    mode         = "READ_WRITE"
    type         = "PERSISTENT"
    disk_encryption_key {
      kms_key_self_link = google_kms_crypto_key.vm-key.id
    }
  }
  network_interface {
    network    = google_compute_network.main_vpc_network[0].name
    subnetwork = google_compute_subnetwork.webapp_subnet[0].name
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
  # service_account {
  #   email  = "service-1039297424411@computesystem.iam.gserviceaccount.com"
  #   scopes = ["cloud-platform"]
  # }

}

resource "google_compute_region_health_check" "http-health-check" {
  name        = "http-health-check"
  description = "Health check via http"

  timeout_sec         = 15
  check_interval_sec  = 15
  healthy_threshold   = 3
  unhealthy_threshold = 5
  region              = var.region
  http_health_check {
    port         = var.app-port
    request_path = "/healthz"
    proxy_header = "NONE"
  }
}

resource "google_compute_region_autoscaler" "appserver" {
  name   = "my-region-autoscaler-${var.ct}"
  region = var.region
  target = google_compute_region_instance_group_manager.appserver.id

  autoscaling_policy {
    max_replicas    = 6
    min_replicas    = 3
    cooldown_period = 60

    cpu_utilization {
      target = var.cpu_utilization_target
    }
  }
  # depends_on = [google_compute_region_instance_group_manager.appserver]
}

resource "google_compute_region_instance_group_manager" "appserver" {
  name                      = "webapp-igm"
  base_instance_name        = "app"
  region                    = var.region
  distribution_policy_zones = ["us-east1-b", "us-east1-c", "us-east1-d"]
  # distribution_policy_target_shape = "BALANCED"
  version {
    instance_template = google_compute_region_instance_template.template.self_link
  }

  all_instances_config {
    metadata = {
      metadata_key = "metadata_value"
    }
    labels = {
      label_key = "label_value"
    }
  }
  update_policy {
    type                           = "PROACTIVE"
    instance_redistribution_type   = "PROACTIVE"
    minimal_action                 = "REPLACE"
    most_disruptive_allowed_action = "REPLACE"
    max_surge_percent              = 0
    max_unavailable_fixed          = 3
    replacement_method             = "RECREATE"
  }

  named_port {
    name = var.port-name
    port = var.app-port
  }

  auto_healing_policies {
    health_check      = google_compute_region_health_check.http-health-check.id
    initial_delay_sec = 300
  }
  depends_on = [google_compute_region_instance_template.template, google_compute_region_health_check.http-health-check]
}
###############################################################################################
#LB for assignment

# backend subnet
resource "google_compute_subnetwork" "proxy_only" {
  name          = "l7-xlb-proxy-only-subnet"
  provider      = google-beta
  ip_cidr_range = var.proxy_subnet_cidr_range
  region        = var.region
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
  network       = google_compute_network.main_vpc_network[0].id
  depends_on    = [google_compute_network.main_vpc_network[0]]
}

resource "google_compute_address" "lb" {
  name         = "l7-xlb-static-ip-new"
  address_type = "EXTERNAL"
  network_tier = "STANDARD"
  region       = var.region
}
# forwarding rule
resource "google_compute_forwarding_rule" "default" {
  name                  = "l7-xlb-forwarding-rule"
  provider              = google-beta
  ip_protocol           = "TCP"
  region                = var.region
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "443"
  target                = google_compute_region_target_https_proxy.default.id
  ip_address            = google_compute_address.lb.address
  network               = google_compute_network.main_vpc_network[0].id
  network_tier          = "STANDARD"
  depends_on            = [google_compute_subnetwork.proxy_only, google_compute_region_target_https_proxy.default, google_compute_address.lb]
}
# ssl certificate
resource "google_compute_region_ssl_certificate" "default" {
  region      = var.region
  name_prefix = "my-ssl-certificate"
  private_key = file(var.ssl_private_key)
  certificate = file(var.ssl_certi)

  lifecycle {
    create_before_destroy = true
  }
}

# https proxy
resource "google_compute_region_target_https_proxy" "default" {
  name             = "l7-xlb-target-https-proxy"
  provider         = google-beta
  region           = var.region
  url_map          = google_compute_region_url_map.default.id
  ssl_certificates = [google_compute_region_ssl_certificate.default.id]
  depends_on       = [google_compute_region_url_map.default, google_compute_region_ssl_certificate.default]
}

# url map
resource "google_compute_region_url_map" "default" {
  name            = "l7-xlb-url-map"
  provider        = google-beta
  region          = var.region
  default_service = google_compute_region_backend_service.default.id
  depends_on      = [google_compute_region_backend_service.default, google_compute_region_ssl_certificate.default]
}

# backend service with custom request and response headers
resource "google_compute_region_backend_service" "default" {
  name                  = "l7-xlb-backend-service"
  provider              = google-beta
  protocol              = "HTTP"
  port_name             = var.port-name
  load_balancing_scheme = var.load-balancing-scheme
  timeout_sec           = 30
  health_checks         = [google_compute_region_health_check.http-health-check.id]
  backend {
    group           = google_compute_region_instance_group_manager.appserver.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
  depends_on = [google_compute_region_instance_group_manager.appserver, google_compute_region_health_check.http-health-check]
}

resource "google_compute_firewall" "default" {
  name = "fw-allow-health-check"
  allow {
    ports    = [var.app-port]
    protocol = "tcp"
  }
  priority      = 600
  direction     = "INGRESS"
  network       = google_compute_network.main_vpc_network[0].id
  source_ranges = [var.gcp_hc_ip1, var.gcp_hc_ip2, var.proxy_subnet_cidr_range]
  target_tags   = [var.instance_tag]
}

# resource "google_compute_firewall" "allow_proxy" {
#   name = "fw-allow-proxies"
#   allow {
#     ports    = ["3000"]
#     protocol = "tcp"
#   }
#   priority      = 600
#   direction     = "INGRESS"
#   network       = google_compute_network.main_vpc_network[0].id
#   source_ranges = ["10.129.0.0/23"]
#   # source_ranges = [google_compute_subnetwork.proxy_only.ip_cidr_range]
#   target_tags = ["load-balanced-backend"]
# }
############################################################################################
# resource "google_service_account" "cmek_service_acc" {
#   account_id   = "cmek-service-account-id-new"
#   display_name = "CMEK Service Account"
#   project      = var.project
# }

# CLOUD KEY RING
resource "google_kms_key_ring" "keyring" {
  name     = "my-keyring-1"
  location = var.region
}


# CLOUD VM CRYPTO KEY
resource "google_kms_crypto_key" "vm-key" {
  name            = "vm-crypto-key"
  key_ring        = google_kms_key_ring.keyring.id
  rotation_period = "2592000s"

  lifecycle {
    prevent_destroy = false
  }
}

# CLOUD VM IAM BINDING
resource "google_kms_crypto_key_iam_binding" "vm_key_binding" {
  provider      = google-beta
  crypto_key_id = google_kms_crypto_key.vm-key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  # members = ["serviceAccount:${google_service_account.service_account.email}"]
  members = ["serviceAccount:service-1039297424411@compute-system.iam.gserviceaccount.com"]

}

# CLOUD SQL CRYPTO KEY
resource "google_kms_crypto_key" "cloudsql-key" {
  provider        = google-beta
  name            = "cloudsql-crypto-key"
  key_ring        = google_kms_key_ring.keyring.id
  rotation_period = "7776000s"
  purpose         = "ENCRYPT_DECRYPT"

  lifecycle {
    prevent_destroy = false
  }
}

# CLOUD SQL SERVICE ACCOUNT & BINDING
resource "google_project_service_identity" "gcp_sa_cloud_sql" {
  provider = google-beta
  service  = "sqladmin.googleapis.com"
}
resource "google_kms_crypto_key_iam_binding" "cloudsql_key_binding" {
  provider      = google-beta
  crypto_key_id = google_kms_crypto_key.cloudsql-key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"

  members = [
    "serviceAccount:${google_project_service_identity.gcp_sa_cloud_sql.email}",
  ]
}

# CLOUD BUCKET CRYPTO KEY
resource "google_kms_crypto_key" "bucket-key" {
  name            = "bucket-crypto-key"
  key_ring        = google_kms_key_ring.keyring.id
  rotation_period = "7776000s"

  lifecycle {
    prevent_destroy = false
  }
}

# BUCKET SERVICE ACCOUNT & BINDING
data "google_storage_project_service_account" "gcs_account" {
}
resource "google_kms_crypto_key_iam_binding" "bucket_key_binding" {
  crypto_key_id = google_kms_crypto_key.bucket-key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"

  members = [
    "serviceAccount:${data.google_storage_project_service_account.gcs_account.email_address}",
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
  depends_on          = [google_service_networking_connection.private_vpc_connection, google_kms_crypto_key_iam_binding.cloudsql_key_binding]
  deletion_protection = false
  encryption_key_name = google_kms_crypto_key.cloudsql-key.id

  settings {
    tier              = "db-custom-2-7680"
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
  name       = "webapp"
  instance   = google_sql_database_instance.postgres.name
  depends_on = [google_sql_database_instance.postgres]

}

resource "random_password" "password" {
  length           = 16
  special          = true
  override_special = "_%@"
}
resource "google_sql_user" "users" {
  name       = "webapp"
  instance   = google_sql_database_instance.postgres.name
  password   = random_password.password.result
  depends_on = [google_sql_database.database, google_sql_database_instance.postgres]
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
    google_compute_address.lb.address,
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
  depends_on    = [google_kms_crypto_key_iam_binding.bucket_key_binding]
  encryption {
    default_kms_key_name = google_kms_crypto_key.bucket-key.id
  }
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
