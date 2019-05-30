#!/bin/bash
red=$(tput setaf 1)
green=$(tput setaf 2)
reset=$(tput sgr0)
TMPDIR=$(mktemp -d)
function helpmenu() {
    echo "Usage: ./checkfix-certs.sh [-y]
-y  When specified checkfix-certs.sh will automatically install required dependencies
"
    exit 1
}
while getopts "hy" opt; do
    case ${opt} in
    h) # process option h
        helpmenu
        ;;
    y) # process option y
        INSTALL_MISSING_DEPENDENCIES=yes
        ;;
    \?)
        helpmenu
        exit 1
        ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

if ! hash curl 2>/dev/null && [ ${INSTALL_MISSING_DEPENDENCIES} == "yes" ]; then
    echo '!!!curl was not found!!!'
    echo 'Please install curl if you want to automatically install missing dependencies'
    exit 1
fi
if ! hash kubectl 2>/dev/null; then
    if [ "${INSTALL_MISSING_DEPENDENCIES}" == "yes" ] && [ "${OSTYPE}" == "linux-gnu" ]; then
        curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
        chmod +x ./kubectl
        mv ./kubectl /bin/kubectl
    else
        echo "!!!kubectl was not found!!!"
        echo "!!!download and install with:"
        echo "Linux users (Run script with option -y to install automatically):"
        echo "curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"
        echo "chmod +x ./kubectl"
        echo "mv ./kubectl /bin/kubectl"
        exit 1
    fi
fi
if ! hash jq 2>/dev/null; then
    if [ "${INSTALL_MISSING_DEPENDENCIES}" == "yes" ] && [ "${OSTYPE}" == "linux-gnu" ]; then
        curl -L -O https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64
        chmod +x jq-linux64
        mv jq-linux64 /bin/jq
    else
        echo '!!!jq was not found!!!'
        echo "!!!download and install with:"
        echo "Linux users (Run script with option -y to install automatically):"
        echo "curl -L -O https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64"
        echo "chmod +x jq-linux64"
        echo "mv jq-linux64 /bin/jq"
        exit 1
    fi
fi
if ! hash sed 2>/dev/null; then
    echo '!!!sed was not found!!!'
    echo 'Sorry no auto install for this one, please use your package manager.'
    exit 1
fi
if ! hash base64 2>/dev/null; then
    echo '!!!base64 was not found!!!'
    echo 'Sorry no auto install for this one, please use your package manager.'
    exit 1
fi

SSLDIRPREFIX=$(docker inspect kubelet --format '{{ range .Mounts }}{{ if eq .Destination "/etc/kubernetes" }}{{ .Source }}{{ end }}{{ end }}')
if [ "$?" != "0" ]; then
    echo "${green}Failed to get SSL directory prefix, aborting script!${reset}"
    exit 1
fi
function setusupthekubeconfig() {
    kubectl --kubeconfig ${SSLDIRPREFIX}/ssl/kubecfg-kube-node.yaml get configmap -n kube-system full-cluster-state -o json &>/dev/null
    if [ "$?" == "0" ]; then
        echo "${green}Deployed with RKE 0.2.x and newer, grabbing kubeconfig${reset}"
        kubectl --kubeconfig ${SSLDIRPREFIX}/ssl/kubecfg-kube-node.yaml get configmap -n kube-system full-cluster-state -o json | jq -r .data.\"full-cluster-state\" | jq -r .currentState.certificatesBundle.\"kube-admin\".config | sed -e "/^[[:space:]]*server:/ s_:.*_: \"https://127.0.0.1:6443\"_" >${TMPDIR}/kubeconfig
    fi
    kubectl --kubeconfig ${SSLDIRPREFIX}/ssl/kubecfg-kube-node.yaml get secret -n kube-system kube-admin -o jsonpath={.data.Config} &>/dev/null
    if [ "$?" == "0" ]; then
        echo "${green}Deployed with RKE 0.1.x and older, grabbing kubeconfig${reset}"
        kubectl --kubeconfig ${SSLDIRPREFIX}/ssl/kubecfg-kube-node.yaml get secret -n kube-system kube-admin -o jsonpath={.data.Config} | base64 -d | sed 's/[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/127.0.0.1/g' >${TMPDIR}/kubeconfig
    fi
    if [ ! -f ${TMPDIR}/kubeconfig ]; then
        echo "${red}${TMPDIR}/kubeconfig does not exist, script aborting due to kubeconfig generation failure.${reset} "
        exit 1
    fi
    export KUBECONFIG=${TMPDIR}/kubeconfig
}
function checkcontent() {
if ! grep -iq "$1" "$2"
then
    echo "${green}Content check on $2 failed test, aborting script!${reset}"
    exit 1
fi
}
function checkfirstpipecmd() {
    if [ "${PIPESTATUS[0]}" != "0" ]
    then
        echo "${green}kubectl command returned non 0 status, aborting script!${reset}"
        exit 1
    fi
}

function diffcheckreplace() {
if ! diff "$1" "$2" &> /dev/null
then
    echo "${red}Difference between $1 and $2 detected, copying new file in place!${reset}"
    cp -afv $1 $2
    else
        echo "${green}No difference between $1 and $2 detected, leaving original file alone.${reset}"
fi
}
setusupthekubeconfig

echo "${green}Testing Kubernetes to make sure our config works${reset}"
echo
kubectl get node
echo
checkfirstpipecmd

#grab certs
NEWCERTDIR="${TMPDIR}/new.ssl/"
echo "${green}Pulling certs from Kubernetes to ${NEWCERTDIR}"
mkdir -p ${TMPDIR}/new.ssl/

#List of files we are working with for the 'for' loops.
kubectl get secret/kube-apiserver-proxy-client -n kube-system -o json | jq -r .data.Certificate | base64 -d > ${NEWCERTDIR}/kube-apiserver-proxy-client.pem
checkfirstpipecmd
checkcontent "BEGIN CERTIFICATE" "${NEWCERTDIR}kube-apiserver-proxy-client.pem"

kubectl get secret/kube-apiserver-proxy-client -n kube-system -o json | jq -r .data.Key | base64 -d > ${NEWCERTDIR}/kube-apiserver-proxy-client-key.pem
checkfirstpipecmd
checkcontent "BEGIN RSA PRIVATE KEY" "${NEWCERTDIR}kube-apiserver-proxy-client-key.pem"

kubectl get secret/kube-apiserver-proxy-client -n kube-system -o yaml > ${NEWCERTDIR}/kubecfg-kube-apiserver-proxy-client.yaml
checkfirstpipecmd
checkcontent "apiVersion" "${NEWCERTDIR}kubecfg-kube-apiserver-proxy-client.yaml"

kubectl get secret/kube-apiserver-requestheader-ca -n kube-system -o yaml > ${NEWCERTDIR}/kubecfg-kube-apiserver-requestheader-ca.yaml
checkfirstpipecmd
checkcontent "apiVersion" "${NEWCERTDIR}kubecfg-kube-apiserver-requestheader-ca.yaml"

kubectl get secret/kube-apiserver-requestheader-ca -n kube-system -o json | jq -r .data.Key | base64 -d > ${NEWCERTDIR}/kube-apiserver-requestheader-ca-key.pem
checkfirstpipecmd
checkcontent "BEGIN RSA PRIVATE KEY" "${NEWCERTDIR}kube-apiserver-requestheader-ca-key.pem"

kubectl get secret/kube-apiserver-requestheader-ca -n kube-system -o json | jq -r .data.Certificate | base64 -d > ${NEWCERTDIR}/kube-apiserver-requestheader-ca.pem
checkfirstpipecmd
checkcontent "BEGIN CERTIFICATE" "${NEWCERTDIR}kube-apiserver-requestheader-ca.pem"

#Verifying we don't have files with content we aren't expecting
checkcontent "BEGIN CERTIFICATE" "${NEWCERTDIR}kube-apiserver-proxy-client.pem"
checkcontent "BEGIN RSA PRIVATE KEY" "${NEWCERTDIR}kube-apiserver-proxy-client-key.pem"
checkcontent "apiVersion" "${NEWCERTDIR}kubecfg-kube-apiserver-proxy-client.yaml"
checkcontent "apiVersion" "${NEWCERTDIR}kubecfg-kube-apiserver-requestheader-ca.yaml"
checkcontent "BEGIN RSA PRIVATE KEY" "${NEWCERTDIR}kube-apiserver-requestheader-ca-key.pem"
checkcontent "BEGIN CERTIFICATE" "${NEWCERTDIR}kube-apiserver-requestheader-ca.pem"


#Backup original certs
echo "${red}Backing up ${SSLDIRPREFIX}/ssl/ to ${TMPDIR}/ssl.backup/${reset}"
mkdir -p ${TMPDIR}/ssl.backup/
cp -arfv ${SSLDIRPREFIX}/ssl/* ${TMPDIR}/ssl.backup/ || { echo "${green}Backup failed, aborting script${reset}"; exit 1;}

#Check for differences in files and copy them in place if there is a difference.
FILES="kube-apiserver-proxy-client.pem
kube-apiserver-proxy-client-key.pem
kubecfg-kube-apiserver-proxy-client.yaml
kubecfg-kube-apiserver-requestheader-ca.yaml
kube-apiserver-requestheader-ca-key.pem
kube-apiserver-requestheader-ca.pem"
for file in ${FILES}
do
    diffcheckreplace "${NEWCERTDIR}/$file"  "${SSLDIRPREFIX}/ssl/${file}"
done

echo "${red}Restarting kube-apiserver kube-controller-manager${reset}"
docker restart kube-apiserver kube-controller-manager
echo
echo "${green}Script has finished successfully${reset}"
echo "${green}${TMPDIR} is the working directory for this script in case you need backups of any files modified or generated in this script${reset}"
