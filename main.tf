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
  name          = "webapp-${uuid()}"
  ip_cidr_range = "10.0.1.0/24"
  network       = google_compute_network.main_vpc_network[count.index].self_link
  region        = "us-west2"
}

resource "google_compute_subnetwork" "db_subnet" {
  count         = var.ct
  name          = "db-${uuid()}"
  ip_cidr_range = "10.0.2.0/24"
  network       = google_compute_network.main_vpc_network[count.index].self_link
  region        = "us-west2"
}

resource "google_compute_route" "webapp_subnet_route" {
  count            = var.ct
  name             = "network-route-${uuid()}"
  dest_range       = "0.0.0.0/0"
  network          = google_compute_network.main_vpc_network[count.index].self_link
  next_hop_gateway = "default-internet-gateway"
  priority         = 100
}

