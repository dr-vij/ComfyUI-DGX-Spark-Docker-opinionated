#!/bin/bash
set -euo pipefail

# Source:
# https://github.com/mmartial/ComfyUI-Nvidia-Docker/blob/main/extras/dgx_spark-helper.sh
# Adapted from instructions seen on
# https://forums.developer.nvidia.com/t/unlocking-the-power-of-the-spark-in-comfyui-no-crashes/360336
#
# Applies a stability profile to the DGX Spark *host* (swap off, GPU persistence
# mode, optional GPU/CPU clock caps), then tails a thermal/clock monitor.

# ---------------------------------------------------------------- defaults ---
GPU_MIN_SPEC="${SPARK_GPU_MIN:-300}"      # MHz or NN% of GPU hardware max
GPU_MAX_SPEC="${SPARK_GPU_MAX:-2100}"     # MHz or NN%; "off" leaves clocks alone
CPU_MAX_SPEC="${SPARK_CPU_MAX:-off}"      # MHz or NN% of CPU hardware max
GOVERNOR="${SPARK_GOVERNOR:-}"            # e.g. schedutil; empty = leave as is
DO_SWAPOFF=1
INTERVAL="${SPARK_INTERVAL:-5}"
LOG_FILE="${SPARK_LOG:-thermal_monitor.log}"
DO_MONITOR=1
DO_RESET=0

usage() {
    cat <<EOF
Usage: ${0##*/} [options]

Clock caps accept either an absolute value in MHz (2100) or a percentage of the
hardware maximum (70%). Pass "off" to leave that clock domain untouched.

  --gpu-max SPEC     GPU clock ceiling   (default: ${GPU_MAX_SPEC}, hw max $(gpu_hw_max 2>/dev/null || echo '?') MHz)
  --gpu-min SPEC     GPU clock floor     (default: ${GPU_MIN_SPEC})
  --cpu-max SPEC     CPU clock ceiling   (default: ${CPU_MAX_SPEC}; only caps
                     cores whose own maximum is higher)
  --governor NAME    cpufreq governor (performance, schedutil, powersave, ...)
  --keep-swap        do not run "swapoff -a"
  --interval SEC     monitor sampling interval (default: ${INTERVAL})
  --log FILE         monitor log file (default: ${LOG_FILE})
  --no-monitor       apply the profile and exit instead of monitoring
  --reset            restore stock clocks/governor, re-enable swap, and exit
  -h, --help         this text

Environment overrides: SPARK_GPU_MIN, SPARK_GPU_MAX, SPARK_CPU_MAX,
SPARK_GOVERNOR, SPARK_INTERVAL, SPARK_LOG

Examples:
  ${0##*/}                          # stock profile: GPU capped at 2100 MHz
  ${0##*/} --gpu-max 70%            # cap GPU at 70% of hardware max
  ${0##*/} --gpu-max 2100 --cpu-max 3500 --governor schedutil
  ${0##*/} --gpu-max off --no-monitor
  ${0##*/} --reset
EOF
}

die() { echo "error: $*" >&2; exit 1; }

# ------------------------------------------------------------- hw discovery ---
gpu_hw_max() {
    nvidia-smi --query-gpu=clocks.max.graphics --format=csv,noheader,nounits 2>/dev/null | tr -d ' '
}

cpu_hw_max() {  # kHz -> MHz, highest core in the machine (big cluster)
    cat /sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq 2>/dev/null \
        | sort -rn | head -1 | awk '{printf "%d", $1/1000}'
}

# resolve_spec <spec> <hw_max_mhz> <label> -> MHz on stdout, empty if "off"
resolve_spec() {
    local spec="$1" hw="$2" label="$3"
    [[ "$spec" == "off" || "$spec" == "none" ]] && return 0
    if [[ "$spec" =~ ^([0-9]+)%$ ]]; then
        [[ -n "$hw" && "$hw" -gt 0 ]] || die "$label: cannot read hardware max, use an absolute MHz value"
        (( BASH_REMATCH[1] >= 1 && BASH_REMATCH[1] <= 100 )) || die "$label: percentage must be 1-100"
        echo $(( hw * BASH_REMATCH[1] / 100 ))
    elif [[ "$spec" =~ ^[0-9]+$ ]]; then
        (( spec >= 100 )) || die "$label: '$spec' looks like a percentage — write '${spec}%'"
        echo "$spec"
    else
        die "$label: bad value '$spec' (expected MHz, NN%, or off)"
    fi
}

# ---------------------------------------------------------------- arg parse ---
while (( $# )); do
    case "$1" in
        --gpu-max)   GPU_MAX_SPEC="${2:?--gpu-max needs a value}"; shift 2 ;;
        --gpu-min)   GPU_MIN_SPEC="${2:?--gpu-min needs a value}"; shift 2 ;;
        --cpu-max)   CPU_MAX_SPEC="${2:?--cpu-max needs a value}"; shift 2 ;;
        --governor)  GOVERNOR="${2:?--governor needs a value}";    shift 2 ;;
        --interval)  INTERVAL="${2:?--interval needs a value}";    shift 2 ;;
        --log)       LOG_FILE="${2:?--log needs a value}";         shift 2 ;;
        --keep-swap) DO_SWAPOFF=0; shift ;;
        --no-monitor) DO_MONITOR=0; shift ;;
        --reset)     DO_RESET=1;   shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           usage >&2; die "unknown option '$1'" ;;
    esac
done

[[ "$INTERVAL" =~ ^[0-9]+$ && "$INTERVAL" -ge 1 ]] || die "--interval must be a positive integer"

command -v nvidia-smi >/dev/null || die "nvidia-smi not found — run this on the Spark host, not in the container"

# ------------------------------------------------------------ resolve specs ---
GPU_HW_MAX="$(gpu_hw_max)"
CPU_HW_MAX="$(cpu_hw_max)"
GPU_MIN_MHZ="$(resolve_spec "$GPU_MIN_SPEC" "$GPU_HW_MAX" '--gpu-min')"
GPU_MAX_MHZ="$(resolve_spec "$GPU_MAX_SPEC" "$GPU_HW_MAX" '--gpu-max')"
CPU_MAX_MHZ="$(resolve_spec "$CPU_MAX_SPEC" "$CPU_HW_MAX" '--cpu-max')"

if [[ -n "$GPU_MAX_MHZ" && -n "$GPU_MIN_MHZ" ]] && (( GPU_MIN_MHZ > GPU_MAX_MHZ )); then
    die "--gpu-min ($GPU_MIN_MHZ MHz) is above --gpu-max ($GPU_MAX_MHZ MHz)"
fi

sudo -v || die "sudo access is required"

# -------------------------------------------------------------------- reset ---
if (( DO_RESET )); then
    sudo nvidia-smi -rgc >/dev/null && echo "GPU clocks: reset to stock"
    for c in /sys/devices/system/cpu/cpu*/cpufreq; do
        [[ -w "$c/scaling_max_freq" || -e "$c/scaling_max_freq" ]] || continue
        sudo tee "$c/scaling_max_freq" < "$c/cpuinfo_max_freq" >/dev/null
    done
    echo "CPU clocks: reset to stock ($(cpu_hw_max) MHz)"
    sudo swapon -a 2>/dev/null && echo "swap: re-enabled" || echo "swap: nothing to enable"
    echo "Reset complete. Governor left as '$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo '?')'."
    exit 0
fi

# ------------------------------------------------------------------- apply ----
## Fix 1: disable swap (critical — unified memory swapping stalls the whole box)
if (( DO_SWAPOFF )); then
    sudo swapoff -a
    echo "swap:      off"
else
    echo "swap:      left as is"
fi

## Fix 2: GPU persistence mode + optional clock cap
sudo nvidia-smi -pm 1 >/dev/null
echo "GPU pm:    on"

if [[ -n "$GPU_MAX_MHZ" ]]; then
    sudo nvidia-smi -lgc "${GPU_MIN_MHZ},${GPU_MAX_MHZ}" >/dev/null
    echo "GPU clock: ${GPU_MIN_MHZ}-${GPU_MAX_MHZ} MHz (hw max ${GPU_HW_MAX:-?} MHz)"
else
    sudo nvidia-smi -rgc >/dev/null 2>&1 || true
    echo "GPU clock: stock (hw max ${GPU_HW_MAX:-?} MHz)"
fi

## Fix 3: optional CPU cap — heterogeneous cores, so clamp per core
if [[ -n "$CPU_MAX_MHZ" ]]; then
    capped=0 skipped=0
    for c in /sys/devices/system/cpu/cpu*/cpufreq; do
        [[ -e "$c/cpuinfo_max_freq" ]] || continue
        core_max_khz=$(< "$c/cpuinfo_max_freq")
        target_khz=$(( CPU_MAX_MHZ * 1000 ))
        if (( target_khz < core_max_khz )); then
            echo "$target_khz" | sudo tee "$c/scaling_max_freq" >/dev/null && capped=$((capped+1))
        else
            echo "$core_max_khz" | sudo tee "$c/scaling_max_freq" >/dev/null && skipped=$((skipped+1))
        fi
    done
    echo "CPU clock: capped at ${CPU_MAX_MHZ} MHz on ${capped} core(s), ${skipped} already below (hw max ${CPU_HW_MAX} MHz)"
else
    echo "CPU clock: stock (hw max ${CPU_HW_MAX} MHz)"
fi

## Fix 4: optional governor
if [[ -n "$GOVERNOR" ]]; then
    avail=$(< /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors)
    [[ " $avail " == *" $GOVERNOR "* ]] || die "governor '$GOVERNOR' unavailable (have: $avail)"
    for c in /sys/devices/system/cpu/cpu*/cpufreq; do
        echo "$GOVERNOR" | sudo tee "$c/scaling_governor" >/dev/null
    done
fi
echo "governor:  $(< /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"

(( DO_MONITOR )) || { echo "Profile applied (monitor skipped)."; exit 0; }

# ----------------------------------------------------------------- monitor ----
echo "Monitoring every ${INTERVAL}s -> ${LOG_FILE} (Ctrl+C to stop; caps stay until --reset)"
printf '### monitor started %s | GPU %s | CPU %s | governor %s\n' \
    "$(date '+%F %T')" \
    "${GPU_MAX_MHZ:-stock}" "${CPU_MAX_MHZ:-stock}" \
    "$(< /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)" >> "$LOG_FILE"

trap 'echo; echo "Stopped. Clock caps are still active — run \"${0##*/} --reset\" to undo."; exit 0' INT TERM

while true; do
    # GPU: one nvidia-smi call for every field, so the samples share a timestamp
    IFS=',' read -r G_TEMP G_PWR G_CLK G_UTIL G_PSTATE G_THROTTLE < <(
        nvidia-smi --query-gpu=temperature.gpu,power.draw,clocks.sm,utilization.gpu,pstate,clocks_event_reasons.active \
                   --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' || echo "?,?,?,?,?,?"
    )

    # CPU: hottest thermal zone, fastest core (zones are unnamed acpitz here)
    CPU_CLK=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null \
              | sort -rn | head -1 | awk '{printf "%d", $1/1000}')
    CPU_TEMP=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null \
               | sort -rn | head -1 | awk '{printf "%d", $1/1000}')
    LOAD=$(awk '{print $1}' /proc/loadavg)

    read -r MEM_USED MEM_TOTAL <<< "$(free -g | awk '/Mem:/{print $3, $2}')"
    SWAP_USED=$(free -g | awk '/Swap:/{print $3}')
    NVME_TEMP=$(awk '{printf "%d", $1/1000}' /sys/class/hwmon/hwmon1/temp1_input 2>/dev/null || echo '-')

    # throttle reasons: 0x0 means "not throttled", anything else is worth seeing
    [[ "$G_THROTTLE" == "0x0000000000000000" ]] && THR="-" || THR="THROTTLE:$G_THROTTLE"

    printf '%s | GPU %3s°C %4sMHz %3s%% %6sW %-2s | CPU %3s°C %4sMHz load %-5s | RAM %s/%sG SWAP %sG | NVMe %s°C %s\n' \
        "$(date '+%F %T')" \
        "$G_TEMP" "$G_CLK" "$G_UTIL" "$G_PWR" "$G_PSTATE" \
        "$CPU_TEMP" "$CPU_CLK" "$LOAD" \
        "$MEM_USED" "$MEM_TOTAL" "$SWAP_USED" \
        "$NVME_TEMP" "$THR" | tee -a "$LOG_FILE"

    sleep "$INTERVAL"
done
