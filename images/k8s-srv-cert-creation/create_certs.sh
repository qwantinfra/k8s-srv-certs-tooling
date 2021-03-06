#!/bin/sh
set -e
set -o pipefail

FORCE_GENERATION=${FORCE_GENERATION:-0}
EMBED_SIGNER_CERT=${EMBED_SIGNER_CERT:-0}
ALL_IN_CERT_FILE=${ALL_IN_CERT_FILE:-0}
SECRET_KEY_CERT=${SECRET_KEY_CERT:-'tls.crt'}
SECRET_KEY_KEY=${SECRET_KEY_KEY:-'tls.key'}

if [ "${FORCE_GENERATION}" == "0" ]; then
  kubectl get csr ${CERT_NAME} && exit 0 || true
else
  kubectl delete csr ${CERT_NAME} || true
fi

TARGET_NS="kube-system"

if [ ! -z "${OBJECTS_CREATED_TARGET_NS}" ]; then
  TARGET_NS="${OBJECTS_CREATED_TARGET_NS}"
fi

cp /in.req /wkd

OLDIFS=${IFS}

env | while IFS='=' read -r name value ; do
  if [ "$(echo ${name} | cut -c 1-8)" = 'CERTREQ_' ]; then
    sed -i "s/\[\[${name}\]\]/${value}/g" /wkd/in.req
  fi
done

alt_names_ref=''

if [ ! -z "${CERTREQ_SAN}" ]; then
  echo "[alt_names]" >> /wkd/in.req
  IFS=','
  i_ip=1
  i_dns=1
  for SAN in ${CERTREQ_SAN}
  do
    if expr "${SAN}" : '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' >/dev/null; then
      echo "IP.${i_ip} = ${SAN}" >> /wkd/in.req
      i_ip=$((i_ip+1))
    else
      echo "DNS.${i_dns} = ${SAN}" >> /wkd/in.req
      i_dns=$((i_dns+1))
    fi
  done
  alt_names_ref="subjectAltName         = @alt_names"
fi

sed -i "s/\[\[ALTNAMES_PLACEHOLDER\]\]/${alt_names_ref}/g" /wkd/in.req

IFS=${OLDIFS}

echo "We will use following req:"

cat /wkd/in.req

openssl genrsa -out /wkd/${SECRET_KEY_KEY} 4096
openssl req -new -config /wkd/in.req -key /wkd/${SECRET_KEY_KEY} -out /wkd/tls.csr

if [ "${alt_names_ref}" != "" ]; then
  openssl req -noout -text -in /wkd/tls.csr | grep DNS
fi

cat <<EOF | kubectl create -f -
apiVersion: certificates.k8s.io/v1beta1
kind: CertificateSigningRequest
metadata:
  name: ${CERT_NAME}
spec:
  groups:
  - system:serviceaccounts
  - system:serviceaccounts:${TARGET_NS}
  - system:authenticated
  request: $(cat /wkd/tls.csr | base64 | tr -d '\n')
  usages:
  - digital signature
  - key encipherment
  - server auth
  - client auth
EOF

echo "Cert ${CERT_NAME} csr submitted to the cluster!"

while true; do
  kubectl get csr ${CERT_NAME} -o jsonpath='{.status.conditions[:1].type}' 2>/dev/null
  if [ "$?" -eq 0 ]; then
    break
  else
    echo "Csr status not retrievable yet!"
  fi
  sleep 2s
done

if [ "${MY_POD_SERVICE_ACCOUNT}" == "server-certs-admin" ]; then
  kubectl certificate approve ${CERT_NAME}
else
  while [ "$(kubectl get csr ${CERT_NAME} -o jsonpath='{.status.conditions[:1].type}')" == "" ]; do
    sleep 20s
    echo "Csr not reviewed yet!"
  done
fi

if [ "$(kubectl get csr ${CERT_NAME} -o jsonpath='{.status.conditions[:1].type}')" == "Approved" ]; then
  echo "Csr approved, we create a matching secret..."

  SECRET_NAME="${CERT_NAME}"

  if [ ! -z "${TLS_SECRET_NAME}" ]; then
    SECRET_NAME="${TLS_SECRET_NAME}"
  fi

  if [ "${ALL_IN_CERT_FILE}" == "0" ]; then
    echo '' > /wkd/${SECRET_KEY_CERT}
  else
    cat /wkd/${SECRET_KEY_KEY} > /wkd/${SECRET_KEY_CERT}
  fi

  kubectl get csr ${CERT_NAME} -o jsonpath='{.status.certificate}' | base64 -d >> /wkd/${SECRET_KEY_CERT}

  if [ "${EMBED_SIGNER_CERT}" == "1" ]; then
    kubectl get cm cluster-info -n kube-public -o=jsonpath='{.data.kubeconfig}' | grep 'certificate-authority-data:' | sed -E 's/^\s*certificate-authority-data:\s*(.+)$/\1/g' | base64 -d >> /wkd/${SECRET_KEY_CERT}
  fi

  kubectl delete --namespace=${TARGET_NS} secret ${SECRET_NAME} || true

  if [ "${ALL_IN_CERT_FILE}" == "0" ]; then
    kubectl create --namespace=${TARGET_NS} secret generic ${SECRET_NAME} --from-file=/wkd/${SECRET_KEY_KEY} --from-file=/wkd/${SECRET_KEY_CERT}
  else
    kubectl create --namespace=${TARGET_NS} secret generic ${SECRET_NAME} --from-file=/wkd/${SECRET_KEY_CERT}
  fi
fi
