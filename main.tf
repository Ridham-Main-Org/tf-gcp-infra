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

resource "google_compute_firewall" "my-firewall" {
  count   = length(google_compute_network.main_vpc_network)
  name    = "${var.firewall_name}-${uuid()}"
  network = google_compute_network.main_vpc_network[count.index].name

  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = var.allowed_ports
  }

  # source_tags = ["web"]
  direction     = var.direction
  source_ranges = ["0.0.0.0/0"]
  target_tags   = [var.instance_tag]
}
resource "google_compute_instance" "vm-instance" {
  count = length(google_compute_network.main_vpc_network)

  name         = "${var.instance-name}-${uuid()}"
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
    network    = google_compute_network.main_vpc_network[count.index].name
    subnetwork = google_compute_subnetwork.webapp_subnet[count.index].name

    access_config {
      // Ephemeral public IP
    }
  }
  metadata_startup_script = "echo hi > /test.txt"
}
