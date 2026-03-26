#!/usr/bin/env bash
# collect-etcd-metrics.sh
# Dependencies: bash, awk, oc

set -euo pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="./etcd-metrics-${TIMESTAMP}"
mkdir -p "${OUTPUT_DIR}"

SUMMARY_FILE="${OUTPUT_DIR}/summary.txt"
echo "Collected: ${TIMESTAMP}" > "${SUMMARY_FILE}"
echo "─────────────────────────────────────────────────────────" >> "${SUMMARY_FILE}"

CURL_CMD="curl -s --cacert /etc/etcd/tls/etcd-ca/ca.crt --cert /etc/etcd/tls/client/etcd-client.crt --key /etc/etcd/tls/client/etcd-client.key https://localhost:2382/metrics"

calc_percentile() {
  local file="$1" prefix="$2" pct="$3"
  awk -v prefix="${prefix}" -v pct="${pct}" '
  BEGIN { count=0; n=0 }
  $0 ~ prefix"_count" && !/bucket/ { count=$2 }
  $0 ~ prefix"_bucket" {
    match($0,/le="([^"]+)"/,arr); les[n]=arr[1]; vals[n]=$2; n++
  }
  END {
    if (count==0) { print "N/A"; exit }
    target=(pct/100.0)*count
    for(i=0;i<n;i++){
      if(vals[i]>=target){
        if(les[i]=="+Inf"){ print ">8192ms"; exit }
        printf "%.1fms\n",les[i]*1000; exit
      }
    }
    print ">8192ms"
  }' "${file}"
}

tail_ops() {
  local file="$1" prefix="$2" threshold="$3"
  awk -v prefix="${prefix}" -v thresh="${threshold}" '
  BEGIN { inf_val=0; thresh_val=-1 }
  $0 ~ prefix"_bucket" {
    match($0,/le="([^"]+)"/,arr); le=arr[1]; val=$2
    if(le=="+Inf")  inf_val=val
    if(le==thresh)  thresh_val=val
  }
  END { if(thresh_val<0) thresh_val=inf_val; printf "%d\n",inf_val-thresh_val }
  ' "${file}"
}

calc_avg_ms() {
  local file="$1" prefix="$2"
  awk -v prefix="${prefix}" '
  BEGIN { s=0; c=0 }
  $0 ~ prefix"_sum"   && !/bucket/ { s=$2 }
  $0 ~ prefix"_count" && !/bucket/ { c=$2 }
  END { if(c>0) printf "%.2fms\n",(s/c)*1000; else print "N/A" }
  ' "${file}"
}

echo "==> Discovering hosted clusters via oc get hcp -A ..."
mapfile -t NAMESPACES < <(oc get hcp -A --no-headers 2>/dev/null | awk '{print $1}')

if [[ ${#NAMESPACES[@]} -eq 0 ]]; then
  echo "ERROR: No HostedControlPlane found. Check MCE/HyperShift installation and permissions."
  exit 1
fi

echo "==> Clusters found:"
for NS in "${NAMESPACES[@]}"; do
  HCP=$(oc get hcp -n "${NS}" --no-headers 2>/dev/null | awk '{print $1}')
  echo "    namespace=${NS}  hcp=${HCP}"
done

for NS in "${NAMESPACES[@]}"; do
  CLUSTER_NAME=$(oc get hcp -n "${NS}" --no-headers 2>/dev/null | awk '{print $1}' | head -1)
  CLUSTER_NAME="${CLUSTER_NAME:-${NS}}"

  echo ""
  echo "==> Cluster: ${CLUSTER_NAME} (${NS})"
  printf "\nCluster: %s\n" "${CLUSTER_NAME}" >> "${SUMMARY_FILE}"

  mapfile -t PODS < <(oc get pods -n "${NS}" --no-headers -l app=etcd 2>/dev/null | awk '{print $1}')
  if [[ ${#PODS[@]} -eq 0 ]]; then
    mapfile -t PODS < <(oc get pods -n "${NS}" --no-headers 2>/dev/null | awk '/^etcd-[0-9]/{print $1}')
  fi
  if [[ ${#PODS[@]} -eq 0 ]]; then
    echo "  WARNING: No etcd pods found in ${NS}"
    continue
  fi

  for POD in "${PODS[@]}"; do
    echo "  -> ${POD}"
    RAW_FILE="${OUTPUT_DIR}/${CLUSTER_NAME}_${POD}.txt"

    if ! oc exec -n "${NS}" "${POD}" -c etcd -- bash -c "${CURL_CMD}" 2>/dev/null \
        | grep -E "etcd_disk_wal_fsync|etcd_disk_backend_commit|etcd_server_leader_changes" \
        > "${RAW_FILE}"; then
      echo "  WARNING: Failed to collect metrics from ${POD}"
      continue
    fi

    LEADER_CHANGES=$(awk '/etcd_server_leader_changes_seen_total/ && !/^#/{print $2}' "${RAW_FILE}")
    LEADER_CHANGES="${LEADER_CHANGES:-0}"

    WAL_AVG=$(calc_avg_ms "${RAW_FILE}" "etcd_disk_wal_fsync_duration_seconds")
    WAL_P99=$(calc_percentile "${RAW_FILE}" "etcd_disk_wal_fsync_duration_seconds" 99)
    WAL_P999=$(calc_percentile "${RAW_FILE}" "etcd_disk_wal_fsync_duration_seconds" 99.9)
    WAL_TAIL=$(tail_ops "${RAW_FILE}" "etcd_disk_wal_fsync_duration_seconds" "0.512")

    BE_P99=$(calc_percentile "${RAW_FILE}" "etcd_disk_backend_commit_duration_seconds" 99)
    BE_P999=$(calc_percentile "${RAW_FILE}" "etcd_disk_backend_commit_duration_seconds" 99.9)
    BE_TAIL=$(tail_ops "${RAW_FILE}" "etcd_disk_backend_commit_duration_seconds" "0.512")

    WAL_P99_WARN=$(awk -v v="${WAL_P99%ms}" 'BEGIN{ if(v+0>10) print "  ABOVE LIMIT (>10ms)" }')
    BE_P99_WARN=$(awk  -v v="${BE_P99%ms}"  'BEGIN{ if(v+0>10) print "  ABOVE LIMIT (>10ms)" }')
    WAL_TAIL_WARN=""; [[ "${WAL_TAIL}" -gt 0 ]] && WAL_TAIL_WARN="  CRITICAL"
    BE_TAIL_WARN="";  [[ "${BE_TAIL}"  -gt 0 ]] && BE_TAIL_WARN="  CRITICAL"

    STATUS="OK"
    [[ "${LEADER_CHANGES}" -gt 10  ]] && STATUS="DEGRADED"
    [[ "${LEADER_CHANGES}" -gt 100 ]] && STATUS="CRITICAL"
    [[ "${WAL_TAIL}"       -gt 10  ]] && STATUS="CRITICAL"

    echo  "  +- ${POD}"
    printf "  |  Leader changes    : %s\n"        "${LEADER_CHANGES}"
    printf "  |  WAL fsync avg     : %s\n"        "${WAL_AVG}"
    printf "  |  WAL fsync P99     : %s %s\n"     "${WAL_P99}"  "${WAL_P99_WARN}"
    printf "  |  WAL fsync P99.9   : %s\n"        "${WAL_P999}"
    printf "  |  WAL fsync >512ms  : %s ops %s\n" "${WAL_TAIL}" "${WAL_TAIL_WARN}"
    printf "  |  Backend P99       : %s %s\n"     "${BE_P99}"   "${BE_P99_WARN}"
    printf "  |  Backend P99.9     : %s\n"        "${BE_P999}"
    printf "  |  Backend >512ms    : %s ops %s\n" "${BE_TAIL}"  "${BE_TAIL_WARN}"
    echo  "  +- STATUS: ${STATUS}"

    printf "  %-20s leader_changes=%-6s wal_p99=%-10s status=%s\n" \
      "${POD}" "${LEADER_CHANGES}" "${WAL_P99}" "${STATUS}" >> "${SUMMARY_FILE}"
  done
done

echo ""
echo "==> Collection complete."
echo "    Files    : ${OUTPUT_DIR}/"
echo "    Summary  : ${SUMMARY_FILE}"
echo ""
echo "--- SUMMARY ---"
cat "${SUMMARY_FILE}"
