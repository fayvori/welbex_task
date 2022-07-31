terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "0.77.0"
    }
  }
  required_version = ">= 0.13"
}

# configure yandex-cloud/yandex provider
provider "yandex" {
  token     = var.yc_token
  cloud_id  = var.yc_cloud_id
  folder_id = var.yc_folder_id
  zone      = var.yc_default_zone
}

# getting the current work folder
data "yandex_resourcemanager_folder" "current_folder" {
  name     = "default"
  cloud_id = var.yc_cloud_id
}

# 1. create yc service account
# 2. bind to created account admin role
# 3. get access and private keys
resource "yandex_iam_service_account" "sa" {
  folder_id = data.yandex_resourcemanager_folder.current_folder.id
  name      = "vmadmin"
}

resource "yandex_resourcemanager_folder_iam_member" "sa_admin" {
  folder_id = data.yandex_resourcemanager_folder.current_folder.id
  role      = "admin"
  member    = "serviceAccount:${yandex_iam_service_account.sa.id}"
}

resource "yandex_iam_service_account_static_access_key" "sa_access_key" {
  service_account_id = yandex_iam_service_account.sa.id
  description        = "static access key for admin user"
}

# create a yandex_vpc and 1 subnet for his
resource "yandex_vpc_network" "vpc_network" {
  name        = "vpc-network"
  description = "vpc for compute instance"
  folder_id   = data.yandex_resourcemanager_folder.current_folder.id
}

resource "yandex_vpc_subnet" "vpc_subnet" {
  v4_cidr_blocks = ["10.2.0.0/16"]
  zone           = "${var.yc_default_zone}-a"
  network_id     = yandex_vpc_network.vpc_network.id
}

# create a yandex vm
resource "yandex_compute_instance" "vm" {
  name               = "welbextaskvm"
  platform_id        = "standard-v1"
  zone               = "${var.yc_default_zone}-a"
  service_account_id = yandex_iam_service_account.sa.id
  folder_id          = data.yandex_resourcemanager_folder.current_folder.id

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      size     = 20
      type     = "network-hdd"
      image_id = "fd8ofg98ci78v262j491"
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.vpc_subnet.id
    nat       = true
  }

  metadata = {
    ssh-keys = "${var.yc_vm_user}:${file("~/.ssh/id_rsa.pub")}"
  }
}

# create alb
# target group -> backend group (with tls) -> http router (and virtual host/hosts) -> alb
resource "yandex_alb_target_group" "alb-tg" {
  name = "alb-target-group"

  target {
    subnet_id  = yandex_vpc_subnet.vpc_subnet.id
    ip_address = yandex_compute_instance.vm.network_interface.0.ip_address
  }
}

resource "yandex_alb_backend_group" "alb-bg" {
  name = "alb-backend-group"

  http_backend {
    name             = "alb-backend"
    weight           = 1
    port             = 80
    target_group_ids = ["${yandex_alb_target_group.alb-tg.id}"]
    load_balancing_config {
      panic_threshold = 0
    }
    healthcheck {
      timeout  = "1s"
      interval = "1s"
      http_healthcheck {
        path = "/"
      }
    }
  }
}

resource "yandex_alb_http_router" "alb-router" {
  name = "http-router"
}

resource "yandex_alb_virtual_host" "virtual-host" {
  name           = "virtual-host"
  http_router_id = yandex_alb_http_router.alb-router.id

  route {
    name = "route"
    http_route {
      http_route_action {
        backend_group_id = yandex_alb_backend_group.alb-bg.id
        timeout          = "1s"
      }
    }
  }
}

resource "yandex_alb_load_balancer" "alb" {
  name = "alb-load-balancer"

  network_id = yandex_vpc_network.vpc_network.id

  allocation_policy {
    location {
      zone_id   = "${var.yc_default_zone}-a"
      subnet_id = yandex_vpc_subnet.vpc_subnet.id
    }
  }

  listener {
    name = "alb-listener"
    endpoint {
      address {
        external_ipv4_address {
        }
      }
      ports = [80]
    }
    http {
      handler {
        http_router_id = yandex_alb_http_router.alb-router.id
      }
    }
  }
}

# get created alb datasource
data "yandex_alb_load_balancer" "data-alb" {
  load_balancer_id = yandex_alb_load_balancer.alb.id
}

# useful outputs for GitLab CI variables
output "vm_info" {
  value       = "${var.yc_vm_user}@${yandex_compute_instance.vm.network_interface.0.nat_ip_address}"
  sensitive   = false
  description = "created vm user and ipv4 address"
}

output "yandex_alb_external_ipv4" {
  value       = data.yandex_alb_load_balancer.data-alb.listener.0.endpoint.0.address.0.external_ipv4_address.0.address
  sensitive   = false
  description = "created public alb ipv4 address"
}