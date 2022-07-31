variable "yc_token" {
  type = string
}

variable "yc_default_zone" {
  type    = string
  default = "ru-central1"
}

variable "yc_cloud_id" {
  type = string
}

variable "yc_folder_id" {
  type = string
}

variable "yc_vm_user" {
  type    = string
  default = "ubuntu"
}