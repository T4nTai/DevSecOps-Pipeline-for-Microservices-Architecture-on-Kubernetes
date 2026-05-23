variable "cluster_name" {
  type = string
}

variable "vault_kms_key_arn" {
  type    = string
  default = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
