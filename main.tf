provider "google" {
  credentials = var.credentials_file
  project     = var.project
  region      = var.region
}

resource "google_compute_network" "main_vpc_network" {
  count                           = var.ct
  name                            = "${var.vpc}-${uuid()}"
  auto_create_subnetworks         = false
  routing_mode                    = var.routing_mode
  delete_default_routes_on_create = true
}

resource "google_compute_subnetwork" "webapp_subnet" {
  count         = var.ct
  name          = "${var.subnet1}-${uuid()}"
  ip_cidr_range = var.cidr-range1
  network       = google_compute_network.main_vpc_network[count.index].self_link
  region        = var.region
}

resource "google_compute_subnetwork" "db_subnet" {
  count         = var.ct
  name          = "${var.subnet2}-${uuid()}"
  ip_cidr_range = var.cidr-range2
  network       = google_compute_network.main_vpc_network[count.index].self_link
  region        = var.region
}

resource "google_compute_route" "webapp_subnet_route" {
  count            = var.ct
  name             = "${var.route1}-${uuid()}"
  dest_range       = var.dest-range
  network          = google_compute_network.main_vpc_network[count.index].self_link
  next_hop_gateway = var.internet-gateway
  priority         = 100
}

resource "google_compute_firewall" "test-firewall" {
  name    = "first-firewall"
  network = google_compute_network.main_vpc_network

  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = ["3000"]
  }

  # source_tags = ["web"]
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["foo-instances"]
}
resource "google_compute_instance" "vm-instance" {
  name         = "${var.instance-name}-${uuid()}"
  machine_type = "n2-standard-2"
  zone         = var.instance-zone

  tags = ["foo-instances"]

  boot_disk {
    initialize_params {
      image = "${var.project}/${var.custom-image-name}"
    }
  }

  network_interface {
    network    = google_compute_network.main_vpc_network
    subnetwork = google_compute_subnetwork.webapp_subnet

    access_config {
      // Ephemeral public IP
    }
  }
  metadata_startup_script = "echo hi > /test.txt"
}


# resource "google_compute_instance" "default" {
#   name         = "${instance-name}-${count}"
#   machine_type = "n2-standard-2"
#   zone         = "us-central1-a"

#   # tags = ["foo", "bar"]

#   boot_disk {
#     initialize_params {
#       image = "${var.project}/${var.custom-image-name}"
#     }
#   }

#   network_interface {
#     network = "default"

#     access_config {
#       // Ephemeral public IP
#     }
#   }
#   metadata_startup_script = "echo hi > /test.txt"
# }

