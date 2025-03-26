#!/usr/bin/bash -l

source ENVS
conda activate $ICENET_CONDA

set -o pipefail
set -eu

if [ $# -lt 2 ] || [ "$1" == "-h" ]; then
    echo "Usage $0 <hemisphere> [osisaf|amsr] [download=0|1]"
    exit 1
fi

HEMI="$1"
SIC_TYPE="$2"
DOWNLOAD=${2:-0}

# download-toolbox integration
# This updates our source
if [ $DOWNLOAD -eq 1 ]; then
  for SOURCE in ${!CMIP6_SOURCES[@]}; do
    echo "SOURCE: $SOURCE"
    for MEMBER in ${CMIP6_SOURCES[$SOURCE]}; do
      echo "MEMBER: $MEMBER"
      COMMAND="download_cmip $DATA_ARGS --source $SOURCE --member $MEMBER $HEMI $CMIP6_DATES $CMIP6_VAR_ARGS"
      echo -e "\n\n$COMMAND\n\n"
      $COMMAND 2>&1 | tee logs/download.cmip_${HEMI}.${SOURCE}.${MEMBER}.log
    done
  done 2>&1 | tee logs/download.cmip_${HEMI}.log
fi

  # download_cmip --source MRI-ESM2-0 --member r1i1p1f1 $DATA_ARGS $HEMI $CMIP6_DATES $CMIP6_VAR_ARGS
