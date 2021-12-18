# ------------------------------------------------------------------------------
# CREATE A PREREQUISITS
# ------------------------------------------------------------------------------

variable "project" {
  description = "Project ID"
  type = string
}

variable "region" {
  description = "Region"
  type = string
}


provider "google" {
  region      = var.region
  project     = var.project
  credentials = file("./service-account.json")
}
 
provider "google-beta" {
  region      = var.region
  project     = var.project
  credentials = file("./service-account.json")
}

resource "google_dns_managed_zone" "dns_prod" {
  name     = "prod-zone"
  dns_name = "prod.domain.com."
}

# ------------------------------------------------------------------------------
# CREATE A STORAGE BUCKET
# ------------------------------------------------------------------------------

resource "google_storage_bucket" "cdn_bucket" {
  name          = "${var.project}-tutorial-medium"
  location      = "US"
  storage_class = "MULTI_REGIONAL"

  uniform_bucket_level_access = true

  website {
    main_page_suffix = "index.html"
    not_found_page   = "404.html"
  }
}

# ------------------------------------------------------------------------------
# CREATE A BACKEND CDN BUCKET
# ------------------------------------------------------------------------------

resource "google_compute_backend_bucket" "cdn_backend_bucket" {
  name        = "cdn-backend-bucket"
  description = "Backend bucket for serving static content through CDN"
  bucket_name = google_storage_bucket.cdn_bucket.name
  enable_cdn  = true
  project     = var.project
}


# ------------------------------------------------------------------------------
# MAKE THE BUCKET PUBLIC
# ------------------------------------------------------------------------------

resource "google_storage_bucket_iam_member" "all_users_viewers" {
  bucket = google_storage_bucket.cdn_bucket.name
  role   = "roles/storage.legacyObjectReader"
  member = "allUsers"
}


# ------------------------------------------------------------------------------
# CREATE A URL MAP
# ------------------------------------------------------------------------------

resource "google_compute_url_map" "cdn_url_map" {
  name            = "cdn-url-map"
  description     = "CDN URL map to cdn_backend_bucket"
  default_service = google_compute_backend_bucket.cdn_backend_bucket.self_link
  project         = var.project
}

# ------------------------------------------------------------------------------
# CREATE A GLOBAL PUBLIC IP ADDRESS
# ------------------------------------------------------------------------------

resource "google_compute_global_address" "cdn_public_address" {
  name         = "cdn-public-address"
  ip_version   = "IPV4"
  address_type = "EXTERNAL"
  project      = var.project
}

# ------------------------------------------------------------------------------
# CREATE A GLOBAL FORWARDING RULE
# ------------------------------------------------------------------------------

resource "google_compute_global_forwarding_rule" "cdn_global_forwarding_rule" {
  name       = "cdn-global-forwarding-https-rule"
  target     = google_compute_target_https_proxy.cdn_https_proxy.self_link
  ip_address = google_compute_global_address.cdn_public_address.address
  port_range = "443"
  project    = var.project
}


# ------------------------------------------------------------------------------
# CREATE DNS RECORD
# ------------------------------------------------------------------------------
 
resource "google_dns_record_set" "cdn_dns_a_record" {
  name         = google_dns_managed_zone.dns_prod.dns_name
  managed_zone = google_dns_managed_zone.dns_prod.name
  type         = "A"
  ttl          = 3600
  rrdatas      = [google_compute_global_address.cdn_public_address.address]
  project      = var.project
}


# ------------------------------------------------------------------------------
# CREATE A GOOGLE COMPUTE MANAGED CERTIFICATE
# ------------------------------------------------------------------------------

resource "google_compute_managed_ssl_certificate" "cdn_certificate" {
  provider    = google-beta
  project     = var.project
 
  name        = "cdn-managed-certificate"
 
  managed {
    domains = [google_dns_managed_zone.dns_prod.dns_name]
  }
}

# ------------------------------------------------------------------------------
# CREATE HTTPS PROXY
# ------------------------------------------------------------------------------
 
resource "google_compute_target_https_proxy" "cdn_https_proxy" {
  name             = "cdn-https-proxy"
  url_map          = google_compute_url_map.cdn_url_map.self_link
  ssl_certificates = [google_compute_managed_ssl_certificate.cdn_certificate.self_link]
  project          = var.project
}


resource "google_service_account" "github_actions" {
  account_id   = "github-actions"
  display_name = "github-actions"
  description  = "Github actions service account"
}

# ------------------------------------------------------------------------------
# CREATE SERVICE ACCOUNT GITHUB ACTIONS
# ------------------------------------------------------------------------------

# It needs to be an objectAdmin on the bucket to be able to
# upload new objects and erase existing objects
resource "google_storage_bucket_iam_member" "assets-admin-iam" {
  bucket = google_compute_backend_bucket.cdn_backend_bucket.bucket_name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.github_actions.email}"
}

# It needs to be a loadBalancer admin to be able 
# to invalidate Cloud CDN caches
resource "google_project_iam_member" "loadbalancer-admin-iam" {
  role    = "roles/compute.loadBalancerAdmin"
  project     = var.project
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}
