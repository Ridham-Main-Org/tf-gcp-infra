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
  # count = length(google_compute_network.main_vpc_network)

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
    echo "DB_HOST=${google_sql_database_instance.postgres.ip_address.0.ip_address}" > /opt/.env
    echo "DB_NAME=${google_sql_database.database.name}" >> /opt/.env
    echo "DB_USER=${google_sql_user.users.name}" >> /opt/.env
    echo "DB_PORT=5432" >> /opt/.env
    echo "DB_PASSWORD=${google_sql_user.users.password}" >> /opt/.env
fi

echo ".env file created with the following content:"
cat /opt/.env
sudo systemctl daemon-reload
sudo systemctl start gcp-centos8.service
sudo systemctl enable gcp-centos8.service

EOT

  service_account {
    email  = google_service_account.service_account.email
    scopes = ["cloud-platform"]
  }

}

resource "google_compute_global_address" "default" {
  # count         = length(google_compute_network.main_vpc_network)
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
  # count    = length(google_compute_network.main_vpc_network)
  provider = google-beta

  network                 = google_compute_network.main_vpc_network[0].id
  service                 = var.service_connection
  reserved_peering_ranges = [google_compute_global_address.default.name]
}

resource "google_sql_database_instance" "postgres" {
  # provider = google-beta
  # count               = length(google_compute_network.main_vpc_network)
  name                = var.postgres_instance_name
  database_version    = var.db_version
  region              = var.region_sql_instance
  depends_on          = [google_service_networking_connection.private_vpc_connection]
  deletion_protection = false

  settings {
    tier = "db-f1-micro"
    # deletion_protection_enabled = false

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
  # count    = length(google_compute_network.main_vpc_network)
  name     = "webapp"
  instance = google_sql_database_instance.postgres.name
}

resource "random_password" "password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}
resource "google_sql_user" "users" {
  # count    = length(google_compute_network.main_vpc_network)
  name     = "webapp"
  instance = google_sql_database_instance.postgres.name
  password = random_password.password.result
}

resource "google_service_account" "service_account" {
  account_id   = "ops-service-account-id"
  display_name = "Ops agent Service Account"
  project      = var.project
}

resource "google_project_iam_binding" "logging-role" {
  project = var.project
  role    = var.logging_role

  members = [
    "serviceAccount:${google_service_account.service_account.email}",
  ]
}

resource "google_project_iam_binding" "monitoring-metric-role" {
  project = var.project
  role    = var.monitoring_role

  members = [
    "serviceAccount:${google_service_account.service_account.email}",
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


