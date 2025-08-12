    provider "google" {
      project     = var.project_id
      zone      = "${var.region}-a"
    }

resource "google_compute_router" "nat-router" {
  name    = "my-router-${var.name}"
  network = google_compute_network.nat-router.self_link
  region  = var.region
}
