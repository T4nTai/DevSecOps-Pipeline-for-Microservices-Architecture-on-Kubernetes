#cloud-config
package_update: true
package_upgrade: true

packages:
  - curl
  - git
  - python3
  - python3-pip

final_message: "Bastion ready"