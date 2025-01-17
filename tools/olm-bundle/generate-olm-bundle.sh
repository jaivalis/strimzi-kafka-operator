#!/usr/bin/env bash
#
# Generates OLM bundle using existing CRDs
#
#
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "$(realpath "$0")")/../multi-platform-support.sh"

PACKAGE_NAME=strimzi-cluster-operator
CHANNELS=latest
PREVIOUS_BUNDLE_VERSION=$(curl -s https://raw.githubusercontent.com/operator-framework/community-operators/master/community-operators/strimzi-kafka-operator/strimzi-kafka-operator.package.yaml | yq e '.channels[0].currentCSV' -)

CSV_TEMPLATE_DIR="$(dirname "$(realpath "$0")")/csv-template"
CSV_TEMPLATE=${CSV_TEMPLATE_DIR}/bases/${PACKAGE_NAME}.clusterserviceversion.yaml

CRD_DIR="$(dirname "$(realpath "$0")")/../../packaging/install/cluster-operator"
BUNDLE="$(dirname "$(realpath "$0")")/bundle"
MANIFESTS=${BUNDLE}/manifests
DOCKERFILE=${BUNDLE}/bundle.Dockerfile

for ARGUMENT in "$@"
do
  KEY=$(echo "$ARGUMENT" | cut -f1 -d=)
  VALUE=$(echo "$ARGUMENT" | cut -f2 -d=)

  case "$KEY" in
    DOCKER_REGISTRY)    DOCKER_REGISTRY=${VALUE} ;;
    DOCKER_ORG)              DOCKER_ORG=${VALUE} ;;
    DOCKER_TAG)              DOCKER_TAG=${VALUE} ;;
    BUNDLE_VERSION)      BUNDLE_VERSION=${VALUE} ;;
    *)
  esac
done

CSV_FILE="${MANIFESTS}/${PACKAGE_NAME}.v${BUNDLE_VERSION}.clusterserviceversion.yaml"

if [[ -z $BUNDLE_VERSION || -z $DOCKER_REGISTRY || -z $DOCKER_ORG || -z $DOCKER_TAG ]]; then
  echo "One or more arguments have not been supplied
Try running:
  ./generate-olm-bundle.sh BUNDLE_VERSION=<BUNDLE_VERSION> DOCKER_REGISTRY=<DOCKER_REGISTRY> DOCKER_ORG=<DOCKER_ORG> DOCKER_TAG=<DOCKER_TAG>
e.g.
  ./generate-olm-bundle.sh BUNDLE_VERSION=0.23.0 DOCKER_REGISTRY=docker.io DOCKER_ORG=strimzi DOCKER_TAG=0.23.0
"
  exit 1
fi

# In order for the operator-sdk to correctly generate a CSV file the CSV_TEMPLATE file
# must have the format ${CSV_TEMPLATE_DIR}/bases/${PACKAGE_NAME}.clusterserviceversion.yaml
if [ ! -f "$CSV_TEMPLATE" ];
then
  echo "ERROR: CSV_TEMPLATE does not follow the format ${CSV_TEMPLATE_DIR}/bases/${PACKAGE_NAME}.clusterserviceversion.yaml"
  exit 1
fi

# In order for the operator-sdk to correctly generate a CSV file the CSV_TEMPLATE file
# metadata.name must of be the format "${PACKAGE_NAME}.v"
CSV_TEMPLATE_METADATA_NAME=$(yq ea '.metadata.name' "${CSV_TEMPLATE}" )
if [[ $CSV_TEMPLATE_METADATA_NAME != ${PACKAGE_NAME}.v* ]];
then
  echo "ERROR: CSV_TEMPLATE metadata.name is not of the format ${PACKAGE_NAME}.v"
  exit 1 
fi

# Generates bundle from existing CRDs
generate_olm_bundle() { 
  rm -rf "${BUNDLE}"
  # To generate a bundle from existing CRDs using the operator-sdk we must:
  #   1.) Specify package name "--package" and bundle version "--version"
  #   2.) Set `--input-dir` to the directory containing CRDs
  #   3.) Place our template CSV file in a directory in the kustomize format: 
  #       "<some-dir>/bases/<package-name>.clusterserviceversion.yaml"
  # *Note* the package name must match the name used in the CSV template
  operator-sdk generate bundle \
	  --input-dir="$CRD_DIR" \
	  --output-dir="$BUNDLE" \
	  --kustomize-dir="$CSV_TEMPLATE_DIR" \
	  --package="$PACKAGE_NAME" \
	  --version="$BUNDLE_VERSION" \
	  --channels="$CHANNELS"
 
  # Move Dockerfile generated by operator-sdk
  mv ./bundle.Dockerfile "$DOCKERFILE"
  
  # Remove last three lines of Dockerfile with incorrectly generated paths
  $HEAD -n -3 "$DOCKERFILE" | $TEE "$DOCKERFILE" 1> /dev/null

  # Add copy commands with correct paths
  echo "COPY ./manifests/ /manifests/" >> "$DOCKERFILE"
  echo "COPY ./metadata/ /metadata/" >> "$DOCKERFILE"
  
  # Remove extra files added by operator-sdk
  rm "${MANIFESTS}/strimzi-cluster-operator_v1_serviceaccount.yaml"

  # Update CSV filename to name traditionally used for OperatorHub
  mv "${MANIFESTS}"/*.clusterserviceversion.yaml "${CSV_FILE}"
  
  # Change the copied CRD names to the names traditionally used for OperatorHub
  for file in "$MANIFESTS"/*; do
    name=$(yq ea '.metadata.name' "${file}")
    kind=$(yq ea '.kind' "${file}")
    if [ "$kind" = "CustomResourceDefinition" ] || [ "$kind" = "ConfigMap" ] ||  [ "$kind" = "ClusterRole" ]; then
      if [ "$kind" = "CustomResourceDefinition" ]; then
        kind="crd"
      else
        name=$(echo "$name" | $SED 's/-//g')
        kind=$(echo "$kind" | tr '[:upper:]' '[:lower:]')
      fi
      dest="${MANIFESTS}/${name}.${kind}.yaml"
      echo "Update CRD filename $(basename "$file") -> $(basename "$dest")"
      mv "$file" "$dest"
    fi
  done
  
  # Copy missing files not added by operator-sdk
  $CP "${CRD_DIR}/030-ClusterRole-strimzi-kafka-broker.yaml" "${MANIFESTS}/strimzikafkabroker.clusterrole.yaml"
  $CP "${CRD_DIR}/031-ClusterRole-strimzi-entity-operator.yaml" "${MANIFESTS}/strimzientityoperator.clusterrole.yaml"
  $CP "${CRD_DIR}/033-ClusterRole-strimzi-kafka-client.yaml" "${MANIFESTS}/strimzikafkaclient.clusterrole.yaml" 
 
  # Update annotations
  yq ea -i 'select(fi==0).metadata.annotations = select(fi==1).metadata.annotations | select(fi==0)' "${CSV_FILE}" "${CSV_TEMPLATE}"
  
  # Update creation timestamp
  yq ea -i ".metadata.annotations.createdAt = \"$(date +'%Y-%m-%d %H:%M:%S')\"" "${CSV_FILE}"

  # Remove unused fields
  yq ea -i "del(.spec.apiservicedefinitions)" "${CSV_FILE}"

  yq ea -i '.spec.install.spec = null' "${CSV_FILE}"
  yq ea -i '.spec.install.spec = {"permissions" : null, "clusterPermissions": null, "deployments": null}' "${CSV_FILE}"
  
  # Update permissions section with namespaced RBAC rules with Cluster Operator roles + Entity Operator roles
  yq ea -i '.spec.install.spec.permissions = [{"rules" : "", "serviceAccountName" : "strimzi-cluster-operator"}]' "${CSV_FILE}"
  yq ea -i 'select(fi==0).spec.install.spec.permissions[0].rules = select(fi==1).rules + select(fi==2).rules | select(fi==0)' \
   "${CSV_FILE}" \
   "${CRD_DIR}/020-ClusterRole-strimzi-cluster-operator-role.yaml" \
   "${CRD_DIR}/031-ClusterRole-strimzi-entity-operator.yaml"
  
  # Update clusterPermissions section with global RBAC rules (operator-sdk incorrectly copys other ClusterRoles here)
  yq ea -i '.spec.install.spec.clusterPermissions = [{"rules" : "", "serviceAccountName" : "strimzi-cluster-operator"}]' "${CSV_FILE}"
  yq ea -i 'select(fi==0).spec.install.spec.clusterPermissions[0].rules = select(fi==1).rules + select(fi==2).rules | select(fi==0)' \
    "${CSV_FILE}" \
		"${CRD_DIR}/021-ClusterRole-strimzi-cluster-operator-role.yaml" \
    "${CRD_DIR}/030-ClusterRole-strimzi-kafka-broker.yaml"

  # Update deployment section (operator-sdk removes fields with empty string values)
  yq ea -i ".spec.install.spec.deployments = [{\"name\": \"${PACKAGE_NAME}-v${BUNDLE_VERSION}\", \"spec\": null}]" "${CSV_FILE}"
  yq ea -i "select(fi==0).spec.install.spec.deployments[0].spec = select(fi==1).spec | select(fi==0)" "${CSV_FILE}" "${CRD_DIR}/060-Deployment-strimzi-cluster-operator.yaml"
  
  # Remove resource sections as it was causing problems with OLM in the past
  yq ea -i 'del(.spec.install.spec.deployments[0].spec.template.spec.containers[0].resources)' "${CSV_FILE}"
  
  yq ea -i 'del(.spec.install.spec.deployments[0].spec.template.spec.containers[0].env[] | select(.name == "STRIMZI_OPERATOR_NAMESPACE"))' "${CSV_FILE}"
  
  yq ea -i ".spec.replaces = \"${PREVIOUS_BUNDLE_VERSION}\" | .spec.replaces style=\"\"" "${CSV_FILE}"
  
  generate_related_images
  generate_image_digests
}

validate_olm_bundle() {
  operator-sdk bundle validate "${BUNDLE}" --select-optional name=operatorhub
}

generate_related_images() {
  # Create relatedImages section
  yq ea -i '.spec.relatedImages = null' "${CSV_FILE}"

  # Add operator image
  image=$(yq ea ".. | select(has(\"image\")) | (select (.name == \"strimzi-cluster-operator\")).image" "${CSV_FILE}")
  yq ea -i ".spec.relatedImages += [{\"name\": \"strimzi-operator\", \"image\": \"$image\"}]" "${CSV_FILE}";
  yq ea -i ".metadata.annotations.containerImage = \"$image\"" "${CSV_FILE}"

  # Add Kafka images
  KAFKA_IMAGE_VALUES=$(yq eval '.. | select(has("name")).env[] | (select (.name == "STRIMZI_KAFKA_IMAGES")).value' "${CSV_FILE}")
  for val in $KAFKA_IMAGE_VALUES;
  do
    name="strimzi-kafka-$(echo "$val" | cut -d'=' -f1 | tr -d '.')";
    image=$(echo "${val}" | cut -d'=' -f2);
    yq ea -i ".spec.relatedImages += [{\"name\": \"$name\", \"image\": \"$image\"}]" "${CSV_FILE}";
  done

  # Add auxiliary images
  ENV="*BRIDGE* *KANIKO_EXECUTOR*"
  for env in $ENV;
  do
    image=$(yq ea ".. | select(has(\"name\")).env[] | (select (.name == \"$env\")).value" "${CSV_FILE}")
    name="strimzi-$(echo "$env" | $SED 's/*//g' | $SED 's/_/-/g' | tr '[:upper:]' '[:lower:]')"
    yq ea -i ".spec.relatedImages += [{\"name\": \"$name\", \"image\": \"$image\"}]" "${CSV_FILE}";
  done
}

# Iterates through images listed in newly generated relatedImages section
# and replaces image tags with image digests
generate_image_digests() {

  IMAGES=$(yq eval '.spec.relatedImages[].image' "${CSV_FILE}")
  for image_tag in $IMAGES;
  do
    tag=$(echo "$image_tag" | cut -d':' -f2);
    image=$(echo "$image_tag" | cut -d':' -f1);
    repo=$(echo "$image" | rev | cut -d'/' -f1 | rev);
    
    if [ "$repo" != "kafka-bridge" ]; then
      tag=$(echo "$tag" | $SED "s/$(echo "$tag" | cut -d'-' -f1)/${DOCKER_TAG}/g")
    fi
    registry=$DOCKER_REGISTRY;
    org=$DOCKER_ORG;

    image="${registry}/${org}/${repo}"
    echo "Get digest from remote registry for image: ${image}:${tag}"
    digest=$(skopeo inspect --format "{{ .Digest }}" "docker://${image}:$tag")
    image_digest="${image}@${digest}"

    echo "Replacing $image_tag with $image_digest"
    $SED -i.bak "s|${image_tag}|${image_digest}|g" "${CSV_FILE}";
		rm "${CSV_FILE}.bak"
  done
}

generate_olm_bundle
validate_olm_bundle
