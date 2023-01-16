# Create network resources
module "vpc" {
  source  = "terraform-google-modules/network/google"
  version = "6.0"

  project_id   = var.project_id
  network_name = "${var.project_name}-vpc"
  routing_mode = "GLOBAL"

  subnets = [
    {
      subnet_name           = "${var.project_name}-subnet"
      subnet_ip             = var.subnetwork_cidr
      subnet_region         = var.region
      subnet_private_access = "true"
    }
  ]

  secondary_ranges = {
    "${var.project_name}-subnet" = [
      {
        range_name    = "${var.project_name}-svcs"
        ip_cidr_range = var.svcs_subnetwork_cidr
      },
      {
        range_name    = "${var.project_name}-pods"
        ip_cidr_range = var.pods_subnetwork_cidr
      },
    ]
  }

  routes = [
    {
      name              = "egress-internet"
      description       = "route through IGW to access internet"
      destination_range = "0.0.0.0/0"
      tags              = "egress-inet"
      next_hop_internet = "true"
    },
  ]
}

module "cloud_router" {
  source  = "terraform-google-modules/cloud-router/google"
  version = "~> 4.0"

  name    = "${var.project_name}-router"
  project = var.project_id
  region  = var.region
  network = module.vpc.network_name

  nats = [{
    name = "${var.project_name}-nat-gw"
  }]
}

resource "google_compute_address" "lb" {
  name = "${var.project_name}-gke-lb"
}

# Create Kubernetes cluster
data "google_client_config" "default" {}

module "gke" {
  source                     = "terraform-google-modules/kubernetes-engine/google//modules/private-cluster"
  version                    = "24.1.0"
  kubernetes_version         = "latest"
  project_id                 = var.project_id
  name                       = var.project_name
  region                     = var.region
  zones                      = var.zones
  network                    = module.vpc.network_name
  subnetwork                 = module.vpc.subnets_names[0]
  ip_range_services          = "${var.project_name}-svcs"
  ip_range_pods              = "${var.project_name}-pods"
  master_ipv4_cidr_block     = "172.16.0.0/28"
  horizontal_pod_autoscaling = true
  enable_private_nodes       = true
  add_cluster_firewall_rules = true
  create_service_account     = true
  remove_default_node_pool   = true

  #  master_authorized_networks = [
  #    {
  #      cidr_block   = var.subnetwork_cidr
  #      display_name = "VPC"
  #    },
  #  ]

  node_pools = [
    {
      name               = "spot-node-pool"
      machine_type       = "e20-medium"
      min_count          = 1
      max_count          = 2
      local_ssd_count    = 0
      spot               = true
      disk_size_gb       = 50
      disk_type          = "pd-standard"
      image_type         = "COS_CONTAINERD"
      enable_gcfs        = false
      enable_gvnic       = false
      auto_repair        = true
      auto_upgrade       = true
      preemptible        = false
      initial_node_count = 1
    },
  ]

  node_pools_oauth_scopes = {
    all = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }

  depends_on = [module.vpc]
}

# Create cluster issuer with letsencrypt
locals {
  cluster_issuer = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name      = "letsencrypt"
      namespace = "default"
    }
    spec = {
      acme = {
        # The ACME server URL
        server = "https://acme-v02.api.letsencrypt.org/directory"
        # Email address used for ACME registration
        email = "jesse.cota@gmail.com"
        # Name of a secret used to store the ACME account private key
        privateKeySecretRef = {
          name = "letsencrypt"
        }
        # Enable the HTTP-01 challenge provider
        solvers = var.solvers
      }
    }
  }
}

resource "kubectl_manifest" "cluster_issuer" {
  yaml_body = var.cluster_issuer_yaml == null ? yamlencode(local.cluster_issuer) : var.cluster_issuer_yaml

  depends_on = [helm_release.cert_manager, helm_release.nginx]
}


# Create required service accounts
resource "google_service_account" "gcr" {
  project      = var.project_id
  account_id   = "sa-${var.project_name}-gcr"
  display_name = "Container Registry - Service Account"
  description  = "Container Registry service account for ${var.project_id}"
}

resource "google_service_account" "app" {
  project      = var.project_id
  account_id   = "sa-${var.project_name}-app"
  display_name = "App - Service Account"
  description  = "App service account for ${var.project_id}"
}

# Create service account private key
resource "google_service_account_key" "gcr" {
  service_account_id = google_service_account.gcr.name
  public_key_type    = "TYPE_X509_PEM_FILE"
}

resource "google_service_account_key" "app" {
  service_account_id = google_service_account.app.name
  public_key_type    = "TYPE_X509_PEM_FILE"
}

# Update free dynamic DNS records
resource "null_resource" "dns_update" {
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]

    environment = {
      DUCKDNS_TOKEN = var.duckdns_token
      LB_ADDRESS    = google_compute_address.lb.address
    }

    command = <<EOT
      echo url="https://www.duckdns.org/update?domains=kanastra-app&token=$DUCKDNS_TOKEN&ip=$LB_ADDRESS" | curl -k -o duck-app.log -K -
      echo url="https://www.duckdns.org/update?domains=kanastra-app-stg&token=$DUCKDNS_TOKEN&ip=$LB_ADDRESS" | curl -k -o duck-app-stg.log -K -
      echo url="https://www.duckdns.org/update?domains=kanastra-app-dev&token=$DUCKDNS_TOKEN&ip=$LB_ADDRESS" | curl -k -o duck-app-stg.log -K -
      echo url="https://www.duckdns.org/update?domains=kanastra-grafana&token=$DUCKDNS_TOKEN&ip=$LB_ADDRESS" | curl -k -o duck-grafana.log -K -
    EOT
  }

  depends_on = [module.gke]
}
