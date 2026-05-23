locals {
  bastion = templatefile("${path.module}/bastion.tpl", {})
  master  = templatefile("${path.module}/master.tpl", {})
  worker = templatefile("${path.module}/worker.tpl", {
    master_dns = var.master_dns
  })
}

variable "master_dns" {
  description = "DNS hostname of master, used in worker cloud-init"
  default     = "master.k8s.internal"
}

output "master" {
  value = base64encode(local.master)
}

output "worker" {
  value = base64encode(local.worker)
}

output "bastion" {
  value = base64encode(local.bastion)
}
