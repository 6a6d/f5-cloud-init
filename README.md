# Overview
This PoC bash script illustrates how to use cloud-init to configure a BIG-IP VE for deployment into a vSphere environment.  As part of this deployment, the F5 automation tool chain is also installed and used license the BIG-IP with BIG-IQ or an individual regkey.

## Requirements

* bash
* docker (uses below imagesx)
  * [yq](https://mikefarah.gitbook.io/yq/)
  * [govc](https://github.com/vmware/govmomi/tree/master/govc)
  * [TMOS Cloud-Init ConfigDrive ISO Builder](https://hub.docker.com/r/f5devcentral/tmos-configdrive-builder)
  * [F5 CLI](https://hub.docker.com/r/f5devcentral/f5-cli)
* [jq](https://stedolan.github.io/jq/)

## Configuration

- If importing locally, add BIG-IP OVA images to the TMOSImages folder.
- Modify the below variables in the '_deploy-bigip-vars.sh' file with appropriate values for your ESXi deployment.
    - CONFIG_DRIVE_DS: variable to the datastore location where the configdrive.iso will be stored
    - CONFIG_DRIVE_FOLDER: datastore folder where the configdrive.iso will be stored
    - CREDS: username and password for BIG-IP
    - MGMT_IP: management IP address of the BIG-IP
- Modify the '_govc-vars.sh' file with appropriate variables for your ESXi deployment.
    - GOVC_URL: vsphere URL
    - GOVC_USERNAME: vsphere administrator username
    - GOVC_PASSWORD: vsphere administrator password
    - GOVC_DATACENTER: default vsphere data center
    - GOVC_DATASTORE: default vsphere datastore
    - GOVC_NETWORK: default network
- Ensure that the deploy-bigip.sh script is executable.

```bash
$ chmod 750 deploy-bigip.sh
```


## Examples

General Usage

```bash
$ deploy-bigip.sh {command} {arg1} {arg2}
```

Import OVA image to vSphere

```bash
$ deploy-bigip.sh import BIGIP-name ./TMOSImages/BIGIP.ova
```

List available templates to clone from

```bash
$ deploy-bigip.sh templates
```

Clone existing OVA template

```bash
$ deploy-bigip.sh clone BIGIP-name BIGIP-template-name
```

Install Declarative Onboarding Extension

```bash
$ deploy-bigip.sh do
```

Install Application Services Extension

```bash
$ deploy-bigip.sh as3
```

Install Telemetry Streaming Extension

```bash
$ deploy-bigip.sh ts
```

Cleanup deployment

```bash
$ deploy-bigip.sh cleanup BIGIP-name
```

## Troubleshooting

Set the DEBUG variable to enable debuging of the bash script if necessary.

```bash
$ DEBUG=true deploy-bigip.sh import BIGIP-name ./TMOSImages/BIGIP.ova
```

## References

* [Declarative Onboarding](https://clouddocs.f5.com/products/extensions/f5-declarative-onboarding/latest/)
* [Application Services 3 Extension](https://clouddocs.f5.com/products/extensions/f5-appsvcs-extension/latest/)
* [Telemetry Streaming](https://clouddocs.f5.com/products/extensions/f5-telemetry-streaming/latest/)
* [Cloud-Init and BIG-IP VE](https://clouddocs.f5.com/cloud/public/v1/shared/cloudinit.html)
* [TMOS Cloud-Init](https://github.com/f5devcentral/tmos-cloudinit)
* [TMOS Image Patcher](https://hub.docker.com/r/f5devcentral/tmos-image-patcher)
* [F5 CLI](https://hub.docker.com/r/f5devcentral/f5-cli)
* [TMOS Cloud-Init ConfigDrive ISO Builder](https://hub.docker.com/r/f5devcentral/tmos-configdrive-builder)
