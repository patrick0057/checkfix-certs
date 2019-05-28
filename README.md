# checkfix-certs.sh
This script will check the following files on your Rancher controlplane node to see if they match what is in your Kubernetes secrets.  If they don't match, then the script will backup the files then replace them.
```
kube-apiserver-proxy-client.pem
kube-apiserver-proxy-client-key.pem
kubecfg-kube-apiserver-proxy-client.yaml
kubecfg-kube-apiserver-requestheader-ca.yaml
kube-apiserver-requestheader-ca-key.pem
kube-apiserver-requestheader-ca.pem
```
### Usage
Option -y will automatically install missing dependencies on linux systems.
```bash
./checkfix-certs.sh -y
```
