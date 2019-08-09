variable "project_id" {
  type = "string"
  description = "GCP Project ID"
}

variable "service_account_credentials" {
  type = "string"
  description = "Path to Service Account key (json)"
}

variable "region" {
  type = "string"
  description = "GCP region, ie. 'us-east4'"
  default = "us-east4"
}

variable "zone" {
  type = "string"
  description = "GCP zone, ie. 'us-east4-a'"
  default = "us-east4-a"
}

variable "subnet_cidr" {
  type = "string"
  description = "IP range of the subnet in CIDR, ie. 10.0.0.0/24"
  default = "10.0.0.0/24"
}

variable "service_account_email" {
  type = "string"
  description = "Email of the GCP service account"
}

variable "ssh_creds_pub" {
  type = "map"
  description = "ssh users and public keys formated as such (including the braces):  { bastion-user = \"~/id_rsa.pub\" }"
}

variable "ssh_creds_priv" {
  type = "map"
  description = "ssh users and private keys formated as such (including the braces):  { bastion-user = \"~/id_rsa\" }"
}


provider "google" {
  credentials = "${file(var.service_account_credentials)}"
  project     = "${var.project_id}"
}

resource "google_compute_network" "genesis-bosh-network" {
  name = "genesis-bosh-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "genesis-bosh-subnetwork" {
  name          = "genesis-bosh-subnetwork"
  ip_cidr_range = "${var.subnet_cidr}"
  region        = "${var.region}"
  network       = "${google_compute_network.genesis-bosh-network.self_link}"
  private_ip_google_access = true
}

resource "google_compute_router" "genesis-bosh-router" {
  name          = "genesis-bosh-router"
  network       = "${google_compute_network.genesis-bosh-network.self_link}"
  region        = "${var.region}"
}

resource "google_compute_router_nat" "genesis-bosh-nat" {
  name          = "genesis-bosh-nat"
  router        = "${google_compute_router.genesis-bosh-router.name}"
  region        = "${var.region}"
  nat_ip_allocate_option = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

resource "google_compute_firewall" "outbound-internet" {
  name          = "outbound-internet"
  network       = "${google_compute_network.genesis-bosh-network.self_link}"
  direction     =  "EGRESS"
  destination_ranges = ["0.0.0.0/0"]
  allow {
    protocol    = "all"
  }
}

resource "google_compute_firewall" "internal-subnet-ingress" {
  name          = "internal-subnet-ingress"
  network       = "${google_compute_network.genesis-bosh-network.self_link}"
  direction     =  "INGRESS"
  source_ranges = ["${var.subnet_cidr}"]
  allow {
    protocol    = "all"
  }
}

resource "google_compute_firewall" "ssh-ingress" {
  name          = "ssh-ingress"
  network       = "${google_compute_network.genesis-bosh-network.self_link}"
  direction     =  "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  allow {
    protocol    = "tcp"
    ports       = ["22"]
  }
}

data "google_compute_image" "ubuntu-xenial" {
  family  = "ubuntu-1604-lts"
  project = "ubuntu-os-cloud"
}

resource "google_compute_disk" "bastion-disk" {
  name  = "bastion-disk"
  zone  = "${var.zone}"
  image = "${data.google_compute_image.ubuntu-xenial.self_link}"
  size  = 50
}

resource "google_compute_instance" "bastion-vm" {
  name         = "bastion-vm"
  machine_type = "n1-standard-2"
  zone         = "${var.zone}"

  boot_disk {
    initialize_params {
      image     = "${data.google_compute_image.ubuntu-xenial.self_link}"
    }
  }

  network_interface {
    network_ip  = "10.0.0.2"
    network     = "${google_compute_network.genesis-bosh-network.self_link}"
    subnetwork  = "${google_compute_subnetwork.genesis-bosh-subnetwork.self_link}"

    access_config {
      // External IP
    }
  }

  attached_disk {
    source = "${google_compute_disk.bastion-disk.self_link}"
  }

  metadata = {
    ssh-keys = join("", [
      for key in keys(var.ssh_creds_pub): 
      "${key}:${file(lookup(var.ssh_creds_pub, key))}"
    ])
  }

  service_account {
    email   = "${var.service_account_email}"
    scopes  = ["cloud-platform"]
  }

  provisioner "remote-exec" {
    inline = [
      "sudo curl -o /usr/local/bin/jumpbox https://raw.githubusercontent.com/starkandwayne/jumpbox/master/bin/jumpbox",
      "sudo chmod 0755 /usr/local/bin/jumpbox",
    ]
    connection {
      type = "ssh"
      host = "${google_compute_instance.bastion-vm.network_interface[0].access_config[0].nat_ip}"
      user = "${keys(var.ssh_creds_priv)[0]}"
      private_key = "${file(lookup(var.ssh_creds_priv, keys(var.ssh_creds_priv)[0]))}"
    }
  }
  provisioner "file" {
    source      = "files/gitconfig"
    destination = "/home/${keys(var.ssh_creds_priv)[0]}/.gitconfig"
    connection {
      type = "ssh"
      host = "${google_compute_instance.bastion-vm.network_interface[0].access_config[0].nat_ip}"
      user = "${keys(var.ssh_creds_priv)[0]}"
      private_key = "${file(lookup(var.ssh_creds_priv, keys(var.ssh_creds_priv)[0]))}"
    }
  }
  provisioner "file" {
    source      = "files/tmux.conf"
    destination = "/home/${keys(var.ssh_creds_priv)[0]}/.tmux.conf"
    connection {
      type = "ssh"
      host = "${google_compute_instance.bastion-vm.network_interface[0].access_config[0].nat_ip}"
      user = "${keys(var.ssh_creds_priv)[0]}"
      private_key = "${file(lookup(var.ssh_creds_priv, keys(var.ssh_creds_priv)[0]))}"
    }
  }
}

output "project_id"      { value = "${var.project_id}" }
output "sa_creds"        { value = "${var.service_account_credentials}" }

output "network_name"    { value = "${google_compute_network.genesis-bosh-network.name}" }
output "subnetwork_name" { value = "${google_compute_subnetwork. genesis-bosh-subnetwork.name}" }
output "network_range"   { value = "${google_compute_subnetwork.genesis-bosh-subnetwork.ip_cidr_range}" }
output "default_gateway" { value = "${google_compute_subnetwork.genesis-bosh-subnetwork.gateway_address}" }
output "avail_zone"      { value = "${google_compute_instance.bastion-vm.zone}" }
output "dns"             { value = "169.254.169.254" }

output "bastion_host_ip" { value = "${google_compute_instance.bastion-vm.network_interface[0].access_config[0].nat_ip}" }
output "ssh_user"        { value = "${keys(var.ssh_creds_pub)[0]}" }
output "ssh_pub_key"     { value = "${var.ssh_creds_pub[keys(var.ssh_creds_pub)[0]]}" }