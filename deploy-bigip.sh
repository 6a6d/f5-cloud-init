#!/usr/local/bin/bash

##
# set script shell options
##
shopt -s expand_aliases
[ "$DEBUG" == 'true' ] && set -x


##
# source shell vars
##
source ./_deploy-bigip-vars.sh
source ./_govc-vars.sh


##
# functions
##
function yq() {
    docker run --rm -i \
        -v "${PWD}":/workdir \
        mikefarah/yq yq --prettyPrint "$@"
}

function f5-cli() {
    docker run --rm -it \
        -v "${PWD}"/.f5_cli:/root/.f5_cli \
        -v "${PWD}":/f5-cli \
        -e "F5_SDK_LOG_LEVEL"=INFO \
        -e "F5_DISABLE_SSL_WARNINGS"=true \
        f5devcentral/f5-cli:latest f5 "$@"
}

function f5-login() {
    f5-cli login --authentication-provider bigip --host "${MGMT_IP}" --user "${CREDS[0]}" --password "${CREDS[1]}"
}

function govc-cli() {
    docker run --rm -it \
        -v "${PWD}":/workdir \
        -e "GOVC_URL"="${GOVC_URL}" \
        -e "GOVC_USERNAME"="${GOVC_USERNAME}" \
        -e "GOVC_PASSWORD"="${GOVC_PASSWORD}" \
        -e "GOVC_TLS_CA_CERTS"="${GOVC_TLS_CA_CERTS}" \
        -e "GOVC_TLS_KNOWN_HOSTS"="${GOVC_TLS_KNOWN_HOSTS}" \
        -e "GOVC_TLS_HANDSHAKE_TIMEOUT"="${GOVC_TLS_HANDSHAKE_TIMEOUT}" \
        -e "GOVC_INSECURE"="${GOVC_INSECURE}" \
        -e "GOVC_DATACENTER"="${GOVC_DATACENTER}" \
        -e "GOVC_DATASTORE"="${GOVC_DATASTORE}" \
        -e "GOVC_NETWORK"="${GOVC_NETWORK}" \
        -e "GOVC_RESOURCE_POOL"="${GOVC_RESOURCE_POOL}" \
        -e "GOVC_HOST"="${GOVC_HOST}" \
        -e "GOVC_GUEST_LOGIN"="${GOVC_GUEST_LOGIN}" \
        -e "GOVC_VIM_NAMESPACE"="${GOVC_VIM_NAMESPACE}" \
        -e "GOVC_VIM_VERSION"="${GOVC_VIM_VERSION}" \
        -e "GOVC_DEBUG_PATH"=- \
        -e "GOVC_DEBUG_PATH_RUN"="${GOVC_DEBUG_PATH_RUN}" \
        -e "GOVMOMI_INSECURE_COOKIES"=false \
        6a6d/govc-alpine:latest govc "${@}"
}

function check-bigip-ready() {
    ssh -oStrictHostKeyChecking=no -i ${PWD}/bigip_rsa ${CREDS[0]}@${MGMT_IP} "source /usr/lib/bigstart/bigip-ready-functions && wait_bigip_ready && wait_bigip_ready config && wait_bigip_ready provision && wait_bigip_ready license"
}

function check-api-status() {
    echo ">> Checking restjavad and restnoded daemon status..."

    apiEndpoint=""
    responseCode=""

    case "${1}" in
        do )
            apiEndpoint="declarative-onboarding"
            ;;
        as3 )
            apiEndpoint="appsvcs"
            ;;
        ts )
            apiEndpoint="telemetry"
            ;;
        * )
            echo ">> API endpoint not set!"
            ;;
    esac

    responseCode="$(curl -u ${CREDS[0]}\:${CREDS[1]} -o /dev/null --insecure --silent --head --write-out '%{http_code}\n' https://$MGMT_IP/mgmt/shared/${apiEndpoint}/info | tr -d '\r')"

    if [ "${responseCode}" != "200" ]; then
        echo ">> Testing API endpoint:" ${apiEndpoint}

        responseCode="$(curl -u ${CREDS[0]}\:${CREDS[1]} -o /dev/null --insecure --silent --head --write-out '%{http_code}\n' https://$MGMT_IP/mgmt/shared/${apiEndpoint}/info | tr -d '\r')"

        count=1

        while [ "${responseCode}" != "200" ]; do
            echo ">> API daemons not ready...sleeping"

            sleep 5

            responseCode="$(curl -u ${CREDS[0]}\:${CREDS[1]} -o /dev/null --insecure --silent --head --write-out '%{http_code}\n' https://$MGMT_IP/mgmt/shared/${apiEndpoint}/info | tr -d '\r')"

            if [ "${count}" == 5 ]; then
                echo ">> API daemons not ready...restarting "

                # TODO: use "bigstart status" instead?
                ssh -oStrictHostKeyChecking=no -i ${PWD}/bigip_rsa ${CREDS[0]}@${MGMT_IP} "bigstart restart restnoded && bigstart restart restjavad"
            fi

            ((count=count+1))
        done

    elif [ "${responseCode}" == "200" ]; then
        return "200"

    else
        echo ">> API b0rk3d...exiting!"
        exit 1
    fi
}

function govc-find-templates() {
    govc-cli find -type m / -config.template true
}

function tmos-configdrive-builder() {
    docker run --rm -it  \
        -v ${PWD}/declarations:/declarations \
        -v ${PWD}:/configdrives \
        -e USERDATA_FILE=/declarations/${USER_DATAFILE} \
        f5devcentral/tmos-configdrive-builder:latest
}

# TODO: implement v15 specific configdrive builder
function tmos-configdrive-builder-15() {
    # tmos-config-drive-builder command for BIG-IP v15+
    docker run --rm -it  \
        -v ${PWD}/declarations:/declarations \
        -v ${PWD}:/configdrives \
        -e USERDATA_FILE=/declarations/${USER_DATAFILE} \
        -e DO_DECLARATION_FILE=/declarations/${DO_FILE} \
        f5devcentral/tmos-configdrive-builder:latest
}

function setup-ssh() {
    echo "// Creating SSH key pair"

    if [ -f ${PWD}/bigip_rsa ]; then
        rm ${PWD}/bigip_rsa*
        ssh-keygen -t rsa -b 4096 -N '' -f ${PWD}/bigip_rsa > /dev/null
        sshKey=$(cat ${PWD}/bigip_rsa.pub)
    else
        ssh-keygen -t rsa -b 4096 -N '' -f ${PWD}/bigip_rsa > /dev/null
        sshKey=$(cat ${PWD}/bigip_rsa.pub)
    fi

    # Add --verbose to debug
    yq write --inplace -- ./declarations/${USER_DATAFILE} 'write_files[1].content' "${sshKey}"
}

function extract-ovf-spec() {
    echo "// Extracting OVF spec file"

    govc-cli import.spec ${OVA_IMAGE} | python -m json.tool > ${OVF_SPEC}
}

function customize-ovf-spec() {
    echo "// Customizing OVF spec file"

    # Change management interface to proper network
    if [ -f ${OVF_SPEC} ]; then
        contents="$(jq '.NetworkMapping[0].Network="mgmt-pg"' ${OVF_SPEC})"
        echo ${contents} > ${OVF_SPEC}

        # Default remaining interfaces
        contents="$(jq '.NetworkMapping[1,2,3].Network="VM Network"' ${OVF_SPEC})"
        echo ${contents} > ${OVF_SPEC}

        # CPU allocation for BIG-IP
        contents="$(jq '.Deployment="quadcpu"' ${OVF_SPEC})"
        echo ${contents} > ${OVF_SPEC}
    else
        echo "//" ${OVF_SPEC} "does not exist!"
        exit 1
    fi
}

# TODO: dynamically create user_data file
function create-user_data-file {
    echo "// Creating user_data file"
}

function validate-cloud-init() {
    echo "// Verifying cloud-init configuration"

    # Validate yaml
    yq v ./declarations/${USER_DATAFILE}; exitStatus=$?

    if [ ${exitStatus} -eq 0 ]; then
        echo ">> yaml validated"
    else
        echo ">> yaml validation failed!"
        exit 1
    fi

    # check if cloud-init exists
    which cloud-init; exitStatus=$?

    if [ ${exitStatus} -eq 0 ]; then
    # TODO: validate cloud-init config
        echo ">> cloud-init found"
        #cloud-init devel schema --config-file my-user-data-file
    else
        echo ">> cloud-init not found...nothing to do"
    fi
}

function create-configdrive-iso() {
    echo "// Creating configdrive.iso"

    # TODO: create BIG-IP version specific configdrive.iso
    tmos-configdrive-builder
}

function upload-configdrive-iso() {
    echo "// Uploading configdrive.iso to datastore" ${CONFIG_DRIVE_DS}

    # TODO: check for existing configdrive iso
    govc-cli datastore.upload -ds ${CONFIG_DRIVE_DS} ./configdrive.iso ${CONFIG_DRIVE_FOLDER}/configdrive.iso
}

function clone-vm-from-template() {
    echo "// Cloning VM"

    govc-cli vm.clone -vm=${OVA_IMAGE} -on=false -waitip=false -ds=borg-nfs-vol3 ${BIGIP_NAME}

    echo ">> changing management network"

    govc-cli vm.network.change -vm ${BIGIP_NAME} -net ${GOVC_NETWORK} ethernet-0

    echo ">> allocating CPU"
    govc vm.change -vm ${BIGIP_NAME} -c 4
}

function import-ova() {
    echo "// Importing OVA"

    results=$(govc-cli find vm -name ${BIGIP_NAME})

    if [ -z "${results}" ]; then
        govc-cli import.ova -options=./${OVF_SPEC} -name=${BIGIP_NAME} ${OVA_IMAGE}
    else
        echo ">>" ${BIGIP_NAME} "exists...exiting!"
        exit 1
    fi
}

function add-cdrom-to-vm() {
    echo "// Adding CD-ROM to" ${BIGIP_NAME}

    govc-cli device.cdrom.add -vm ${BIGIP_NAME} > /dev/null
    govc-cli device.cdrom.insert -vm ${BIGIP_NAME} -device cdrom-3000 -ds ${CONFIG_DRIVE_DS} ${CONFIG_DRIVE_FOLDER}/configdrive.iso
    govc-cli device.connect -vm ${BIGIP_NAME} cdrom-3000
}

function power-on-vm() {
    echo "// Powering up" ${BIGIP_NAME}

    govc-cli vm.power -on ${BIGIP_NAME}
    tempIP=$(govc-cli vm.ip -n ethernet-0 ${BIGIP_NAME} | cut -d, -f2  | tr -d '\r')

    while [ -z "${tempIP}" ]; do
        echo ">> waiting for IP address..."

        tempIP=$(govc-cli vm.ip -n ethernet-0 ${BIGIP_NAME} | cut -d, -f2 | tr -d '\r')

        sleep 15
    done

    while [ "${tempIP}" != "${MGMT_IP}" ]; do
        echo ">> Management IP is" ${tempIP} "but should be" ${MGMT_IP} "...sleeping"

        tempIP=$(govc-cli vm.ip -n ethernet-0 ${BIGIP_NAME} | cut -d, -f2 | tr -d '\r')

        sleep 15
    done

    echo ">> Management IP of" ${BIGIP_NAME} "is" ${MGMT_IP}
}

function is-bigip-ready() {
    echo "// Checking BIG-IP daemons"

    bigipStatus=check-bigip-ready

    while [ ! "$bigipStatus" ]; do
        echo ">> BIP-IP not ready...sleeping"

        bigipStatus=check-bigip-ready

        sleep 15
    done
}

function configure-f5-cli() {
    echo "// Logging into BIG-IP"

    # TODO: check if f5-cli can log into BIG-IP
    # TODO: handle error output "Error: Device is not ready."

    if [ check-bigip-ready ]; then
        # create login object
        f5-cli login --authentication-provider bigip --host ${MGMT_IP} --user ${CREDS[0]} --password ${CREDS[1]}

    else
        echo ">> BIG-IP not ready...exiting!"
        exit 1
    fi
}

function f5-cli-do() {
    configure-f5-cli

    f5-cli bigip extension do install
    f5-cli bigip extension do verify
}

function install-do() {
    configure-f5-cli

    echo "// Install DO"

    if [ check-bigip-ready ]; then
        f5-cli bigip extension do install
        f5-cli bigip extension do verify

        # ensure restjavad and restnoded are ready to accept declarations
        check-api-status do

        echo ">> Daemons ready to go!"

    else
        echo "// BIG-IP not ready...exiting!"
        exit 1
    fi
}

function install-as3() {
    configure-f5-cli

    echo "// Install AS3"

    if [ check-bigip-ready ]; then
        f5-cli bigip extension as3 install
        f5-cli bigip extension as3 verify

        # ensure restjavad and restnoded are ready to accept declarations
        check-api-status as3

        echo ">> Daemons ready to go!"

    else
        echo "// BIG-IP not ready...exiting!"
        exit 1
    fi
}

function install-ts() {
    configure-f5-cli

    echo "// Install TS"

    if [ check-bigip-ready ]; then
        f5-cli bigip extension ts install
        f5-cli bigip extension ts verify

        # ensure restjavad and restnoded are ready to accept declarations
        check-api-status ts

        echo ">> Daemons ready to go!"

    else
        echo "// BIG-IP not ready...exiting!"
        exit 1
    fi
}

function license-bigip() {
    echo "// Licensing BIG-IP with DO"

    if [ check-bigip-ready ]; then
        f5-cli bigip extension do create --declaration ./declarations/bigip-license.json

    else
        echo "// BIG-IP not ready...exiting!"
        exit 1
    fi
}

function config-bigip() {
    echo "// Configuring BIG-IP with DO"

    if [ check-bigip-ready ]; then
        f5-cli bigip extension do create --declaration ./declarations/bigip-configure.json

    else
        echo "// BIG-IP not ready...exiting!"
    fi
}

function revoke-license() {
    # TODO: fix revoking process with BIG-IQ
    configure-f5-cli

    echo "// Revoking BIG-IP license with DO"

    # Set revokeFrom in DO_LICENSE_FILE
    contents="$(jq '.Common.myLicense.revokeFrom="best-25m"' ./declarations/${DO_LICENSE_FILE})"
    echo ${contents} > ./declarations/${DO_LICENSE_FILE}

    if [ check-bigip-ready ]; then
        f5-cli bigip extension do create --declaration ./declarations/${DO_LICENSE_FILE}

    else
        echo "// BIG-IP not ready...exiting!"
    fi

    # Unset revokeFrom in DO_LICENSE_FILE
    contents="$(jq '.Common.myLicense.revokeFrom=""' ./declarations/${DO_LICENSE_FILE})"
    echo ${contents} > ./declarations/${DO_LICENSE_FILE}
}

function power-off-vm() {
    echo "// Shuting down" ${BIGIP_NAME}

    govc-cli vm.power -off ${BIGIP_NAME}
    govc-cli device.remove -vm ${BIGIP_NAME} cdrom-3000
}

function delete-vm() {
    echo "// Deleting" ${BIGIP_NAME}

    govc-cli vm.destroy ${BIGIP_NAME}
}

function delete-configdrive-iso() {
    echo "// Deleting configdrive.iso"

    govc-cli datastore.rm -ds ${CONFIG_DRIVE_DS} ${CONFIG_DRIVE_FOLDER}/configdrive.iso
}

function clean-up() {
    echo "// Cleaning up!"

    if [ -f "${PWD}/${OVF_SPEC}" ]; then
        rm ${PWD}/${OVF_SPEC}
    else
        echo ">>" ${OVF_SPEC} "does not exist...nothing to do!"
    fi

    if [ -f "${PWD}/configdrive.iso" ]; then
        rm ${PWD}/configdrive.iso
    else
        echo ">> configdrive.iso does not exist...nothing to do!"
    fi

    if [ -f "${PWD}/bigip_rsa" ]; then
        rm ${PWD}/bigip_rsa*
    else
        echo ">> ssh keys do not exist...nothing to do!"
    fi

    echo ">> removing" ${MGMT_IP} "from ~/.ssh/known_hosts"
    ssh-keygen -R ${MGMT_IP} 2> /dev/null

    power-off-vm
    delete-vm
    delete-configdrive-iso
}


##
# main
##
if [ "${1}" == "cleanup" ]; then
    revoke-license
    clean-up

elif [ "${1}" == "clone" ]; then
    setup-ssh
    validate-cloud-init
    create-configdrive-iso
    upload-configdrive-iso
    clone-vm-from-template
    add-cdrom-to-vm
    power-on-vm
    install-do
    license-bigip
    config-bigip

elif [ "${1}" == "import" ]; then
    setup-ssh
    validate-cloud-init
    extract-ovf-spec
    customize-ovf-spec
    create-configdrive-iso
    upload-configdrive-iso
    import-ova
    add-cdrom-to-vm
    power-on-vm
    install-do
    license-bigip
    config-bigip

elif [ "${1}" == "govc" ]; then
    args=${@:2}

    govc-cli ${args}

elif [ "${1}" == "templates" ]; then
    govc-find-templates

elif [ "${1}" == "check-bigip" ]; then
    check-bigip-ready

elif [ "${1}" == "do" ]; then
    install-do

elif [ "${1}" == "as3" ]; then
    install-as3

elif [ "${1}" == "ts" ]; then
    install-ts

elif [ "${1}" == "license" ]; then
    license-bigip

elif [ "${1}" == "config" ]; then
    config-bigip

elif [ "${1}" == "revoke" ]; then
    revoke-license
fi
