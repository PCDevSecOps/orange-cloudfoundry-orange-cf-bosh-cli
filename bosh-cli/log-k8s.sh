#!/bin/bash
#===========================================================================
# Log to kubernetes clusters for clis (kubectl, helm, k9s)
#===========================================================================

#--- Update propertie value from KUBECONFIG file
updateKubeConfig() {
  key_path="$1"
  key_value="$2"
  yaml_file="${KUBECONFIG}"
  new_file="${KUBECONFIG}.tmp"

  if [ ! -s ${yaml_file} ] ; then
    printf "\n%bERROR : File \"${yaml_file}\" unknown.%b\n" "${RED}" "${STD}" ; flagError=1
  else
    > ${new_file}
    awk -v new_file="${new_file}" -v refpath="${key_path}" -v value="${key_value}" 'BEGIN {nb = split(refpath, path, ".") ; level = 1 ; flag = 0 ; string = ""}
    {
      line = $0
      currentLine = $0 ; gsub("^ *", "", currentLine) ; gsub("^ *- *", "", currentLine)
      key = path[level]":"
      if (index(currentLine, key) == 1) {
        if(level == nb) {
          level = level + 1 ; path[level] = "@" ; flag = 1
          sub("^ *", "", value) ; sub(" *$", "", value)
          gsub(":.*", ": "value, line)
        }
        else {level = level + 1}
        string = string "\n" line
      }
      printf("%s\n", line) >> new_file
    }
    END {if(flag == 0){exit 1}}' ${yaml_file}

    if [ $? != 0 ] ; then
      printf "\n%bERROR: Unknown key [${key_path}] in file \"${yaml_file}\".%b\n" "${RED}" "${STD}" ; flagError=1
    else
      cp ${new_file} ${yaml_file}
    fi
    rm -f ${new_file} > /dev/null 2>&1
    chmod 600 ${yaml_file} > /dev/null 2>&1
  fi
}

#--- Get k8s cluster configuration from credhub
getClusterConfiguration() {
  credhub g -n /kubeconfigs/${K8S_DEPLOYMENT} -j 2> /dev/null | jq -r '.value' > ${KUBECONFIG}
  if [ -s ${KUBECONFIG} ] ; then
    updateKubeConfig "clusters.name" "${K8S_DEPLOYMENT}"
    updateKubeConfig "contexts.context.cluster" "${K8S_DEPLOYMENT}"
    updateKubeConfig "contexts.name" "${K8S_CLUSTER}"
    updateKubeConfig "users.name" "${K8S_CLUSTER}"
    updateKubeConfig "contexts.context.user" "${K8S_CLUSTER}"
    updateKubeConfig "current-context" "${K8S_CLUSTER}"
    TARGET_KUBECONFIG="${TARGET_KUBECONFIG}:${KUBECONFIG}"
  else
    rm -f ${KUBECONFIG} > /dev/null 2>&1
  fi
}

#--- Select k8s cluster
selectCluster() {
  case "$1" in
    "1") K8S_DEPLOYMENT="00-core-connectivity-k8s" ; K8S_CLUSTER="core-connectivity" ;;
    "2") K8S_DEPLOYMENT="01-ci-k8s" ; K8S_CLUSTER="ci" ;;
    "3") K8S_DEPLOYMENT="00-gitops-management" ; K8S_CLUSTER="gitops-management" ;;
    "4") K8S_DEPLOYMENT="00-supervision" ; K8S_CLUSTER="supervision" ;;
    "5") K8S_DEPLOYMENT="00-k3s-serv" ; K8S_CLUSTER="services" ;;
    "6") K8S_DEPLOYMENT="k3s-sandbox" ; K8S_CLUSTER="sandbox" ;;
    *) flag=0 ; clear ;;
  esac
}

#--- Create k8s configration directory
if [ ! -d ${HOME}/.kube ] ; then
  mkdir ${HOME}/.kube > /dev/null 2>&1
fi

#--- Log to credhub
flagError=0
flag=$(credhub f > /dev/null 2>&1)
if [ $? != 0 ] ; then
  printf "\n%bLDAP user and password :%b\n" "${REVERSE}${GREEN}" "${STD}"
  printf "username: " ; read LDAP_USER
  credhub login --server=https://credhub.internal.paas:8844 -u ${LDAP_USER}
  if [ $? != 0 ] ; then
    printf "\n%bERROR : LDAP authentication failed with \"${LDAP_USER}\" account.%b\n" "${RED}" "${STD}" ; flagError=1
  fi
fi

#--- Log to k8s
if [ ${flagError} = 0 ] ; then
  #--- Get k3s clusters configuration
  TARGET_KUBECONFIG=""
  clear
  printf "\n%bGet clusters properties...%b\n" "${YELLOW}${REVERSE}" "${STD}"
  if [ "${SITE_NAME}" = "fe-int" ] ; then
    MAX_ITEMS=6
  else
    MAX_ITEMS=5
  fi

  for value in $(seq 1 ${MAX_ITEMS}) ; do
    selectCluster "${value}"
    export KUBECONFIG="${HOME}/.kube/${K8S_CLUSTER}.yml"
    if [ -s ${KUBECONFIG} ] ; then
      #--- Check if k8s cluster is accessible
      kubectl get namespaces --request-timeout='2s' >/dev/null 2>&1
      if [ $? = 0 ] ; then
        updateKubeConfig "clusters.name" "${K8S_DEPLOYMENT}"
        updateKubeConfig "contexts.context.cluster" "${K8S_DEPLOYMENT}"
        updateKubeConfig "contexts.name" "${K8S_CLUSTER}"
        updateKubeConfig "users.name" "${K8S_CLUSTER}"
        updateKubeConfig "contexts.context.user" "${K8S_CLUSTER}"
        updateKubeConfig "current-context" "${K8S_CLUSTER}"
        TARGET_KUBECONFIG="${TARGET_KUBECONFIG}:${KUBECONFIG}"
      else
        getClusterConfiguration
      fi
    else
      getClusterConfiguration
    fi
  done

  #--- Install svcat plugin (need to unset KUBECONFIG for using default path ${HOME}/.kube)
  unset KUBECONFIG
  svcat install plugin > /dev/null 2>&1

  #--- Select kubernetes cluster to work with
  flag=0
  while [ ${flag} = 0 ] ; do
    flag=1
    printf "\n%bKubernetes cluster :%b\n\n" "${REVERSE}${GREEN}" "${STD}"
    printf "%b1%b : k3s core connectivity\n" "${GREEN}${BOLD}" "${STD}"
    printf "%b2%b : k3s ci\n" "${GREEN}${BOLD}" "${STD}"
    printf "%b3%b : k3s gitops management\n" "${GREEN}${BOLD}" "${STD}"
    printf "%b4%b : k3s supervision\n" "${GREEN}${BOLD}" "${STD}"
    printf "%b5%b : k3s services\n" "${GREEN}${BOLD}" "${STD}"
    if [ "${SITE_NAME}" = "fe-int" ] ; then
      printf "%b6%b : k3s sandbox\n" "${GREEN}${BOLD}" "${STD}"
    fi
    printf "\n%bYour choice :%b " "${GREEN}${BOLD}" "${STD}" ; read choice
    selectCluster "${choice}"
    export KUBECONFIG="${HOME}/.kube/${K8S_CLUSTER}.yml"
  done

  #--- Concatenate clusters config files and set current context
  if [ ! -f ${KUBECONFIG} ] ; then
    printf "\n%bERROR : Get \"${K8S_DEPLOYMENT}\" cluster configuration failed.%b\n" "${RED}" "${STD}"
  else
    export KUBECONFIG="$(echo "${TARGET_KUBECONFIG}" | sed -e "s+^:++")"
    kubectl config view --flatten > ${HOME}/.kube/config
    export KUBECONFIG="${HOME}/.kube/config"
    kubectl config use-context ${K8S_CLUSTER} > /dev/null 2>&1
    result=$?

    #--- Install svcat auto-completion
    source <(svcat completion bash)

    #--- Display cluster namespaces
    if [ ${result} = 0 ] ; then
      printf "\n%bCluster \"${K8S_CLUSTER}\" namespaces:%b\n" "${YELLOW}${REVERSE}" "${STD}"
      kubectl get namespaces
    else
      printf "\n%bERROR : Cluster \"${K8S_DEPLOYMENT}\" is not available.%b\n" "${RED}" "${STD}"
    fi
  fi
fi