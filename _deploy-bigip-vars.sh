##
# global vars
##
export BIGIP_NAME=${2}
export OVA_IMAGE=${3}
export OVF_SPEC=${BIGIP_NAME}-ovf-spec.json
export USER_DATAFILE='user-data.yaml'
export DO_FILE='bigip-configure.json'
export DO_LICENSE_FILE='bigip-license.json'
export CONFIG_DRIVE_DS=''
export CONFIG_DRIVE_FOLDER=''
export CREDS=(admin putPasswordHere)
export MGMT_IP=''
export TMP_DIR='${PWD}/tmp/'
