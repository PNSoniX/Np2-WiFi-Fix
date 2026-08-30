#!/system/bin/sh

MODDIR=/data/adb/modules/nothing_phone2_wifi_fix
LOGFILE="$MODDIR/wifi_fix.log"

CNSS_DEVICE="b0000000.qcom,cnss-qca6490"
CNSS_DRIVER="/sys/bus/platform/drivers/cnss2"
CNSS_DEVICE_PATH="/sys/devices/platform/soc/$CNSS_DEVICE"
FS_READY="$CNSS_DEVICE_PATH/fs_ready"

PERSIST_DIR="/mnt/vendor/persist/wlan"
PERSIST_CFG="$PERSIST_DIR/WCNSS_qcom_cfg.ini"
VENDOR_CFG="/vendor/etc/wifi/qca6490/WCNSS_qcom_cfg.ini"

WLAN_MODULE="/vendor/lib/modules/qca_cld3_qca6490.ko"

log()
{
    echo "[$(date)] $*" >> "$LOGFILE"
}

echo "[$(date)] WiFi fix service started" > "$LOGFILE"


#
# Already working?
#
if ip link show wlan0 >/dev/null 2>&1; then
    log "wlan0 already exists - SUCCESS"
    exit 0
fi


#
# Wait for Android to finish early boot.
#
log "Waiting for Android boot completion..."

for i in $(seq 1 120); do
    BOOT_COMPLETED="$(getprop sys.boot_completed)"

    if [ "$BOOT_COMPLETED" = "1" ]; then
        log "Android boot completed after ${i}s"
        break
    fi

    sleep 1
done

if [ "$(getprop sys.boot_completed)" != "1" ]; then
    log "WARNING: sys.boot_completed never became 1"
fi


#
# Give PCI / Bluetooth / CNSS / power management some extra settling time.
#
log "Waiting 10 seconds for hardware initialization to settle..."
sleep 10


#
# Android might have fixed WiFi itself meanwhile.
#
if ip link show wlan0 >/dev/null 2>&1; then
    log "wlan0 appeared normally - SUCCESS"
    exit 0
fi


#
# Wait for persist.
#
log "Waiting for persist filesystem..."

for i in $(seq 1 30); do
    if [ -d /mnt/vendor/persist ]; then
        log "persist available"
        break
    fi

    sleep 1
done


#
# Repair persist/wlan if necessary.
#
if [ ! -f "$PERSIST_CFG" ]; then

    log "WCNSS_qcom_cfg.ini missing - repairing"

    mkdir -p "$PERSIST_DIR"

    if [ ! -f "$VENDOR_CFG" ]; then
        log "ERROR: vendor WiFi config missing"
        exit 1
    fi

    cp "$VENDOR_CFG" "$PERSIST_CFG"

    chown wifi:wifi "$PERSIST_DIR"
    chown wifi:wifi "$PERSIST_CFG"

    chmod 755 "$PERSIST_DIR"
    chmod 644 "$PERSIST_CFG"

    chcon u:object_r:wifi_vendor_data_file:s0 "$PERSIST_DIR" \
        2>> "$LOGFILE"

    chcon u:object_r:wifi_vendor_data_file:s0 "$PERSIST_CFG" \
        2>> "$LOGFILE"

    log "persist/wlan repaired"

else
    log "persist/wlan OK"
fi


#
# Wait for CNSS2.
#
log "Waiting for cnss2..."

for i in $(seq 1 60); do
    if [ -d "$CNSS_DRIVER" ]; then
        break
    fi

    sleep 1
done

if [ ! -d "$CNSS_DRIVER" ]; then
    log "ERROR: cnss2 unavailable"
    exit 1
fi


#
# Bind device if necessary.
#
if [ ! -e "$CNSS_DRIVER/$CNSS_DEVICE" ]; then

    log "Binding QCA6490 to cnss2..."

    echo "$CNSS_DEVICE" > "$CNSS_DRIVER/bind" 2>> "$LOGFILE"

    sleep 2

else
    log "QCA6490 already bound"
fi


#
# Wait for fs_ready.
#
for i in $(seq 1 30); do

    if [ -e "$FS_READY" ]; then
        break
    fi

    sleep 1

done

if [ ! -e "$FS_READY" ]; then
    log "ERROR: fs_ready unavailable"
    exit 1
fi


#
# Correct module detection.
#
if grep -q '^qca6490 ' /proc/modules; then
    log "qca6490 module already loaded"
else

    log "qca6490 module not loaded - loading it"

    insmod "$WLAN_MODULE" 2>> "$LOGFILE"

    sleep 2

fi


#
# Enable CNSS recovery rather than allowing WLAN crash to reboot/panic
# on kernels supporting this control.
#
if [ -e "$CNSS_DEVICE_PATH/recovery" ]; then
    log "Enabling CNSS recovery"
    echo 1 > "$CNSS_DEVICE_PATH/recovery" 2>> "$LOGFILE"
fi


#
# fs_ready retry loop.
#
# PCI resume sometimes returns -EAGAIN on this device.
#
for ATTEMPT in 1 2 3 4; do

    if ip link show wlan0 >/dev/null 2>&1; then

        ip link set wlan0 up 2>> "$LOGFILE"

        log "wlan0 UP before attempt $ATTEMPT - SUCCESS"
        exit 0

    fi


    log "Triggering fs_ready - attempt $ATTEMPT"

    SELINUX_STATE="$(getenforce 2>/dev/null)"

    setenforce 0 2>/dev/null

    echo 1 > "$FS_READY" 2>> "$LOGFILE"

    if [ "$SELINUX_STATE" = "Enforcing" ]; then
        setenforce 1 2>/dev/null
    fi


    #
    # Cold boot calibration is asynchronous.
    #
    # Don't hammer fs_ready repeatedly; give CNSS enough time to
    # finish or fail the PCI power-up attempt.
    #
    log "Waiting for wlan0 after attempt $ATTEMPT..."

    for i in $(seq 1 20); do

        sleep 1

        if ip link show wlan0 >/dev/null 2>&1; then

            ip link set wlan0 up 2>> "$LOGFILE"

            log "wlan0 UP on attempt $ATTEMPT after ${i}s - SUCCESS"
            exit 0

        fi

    done


    log "Attempt $ATTEMPT did not create wlan0"

    #
    # Wait before retrying PCI/cold boot calibration.
    #
    if [ "$ATTEMPT" -lt 4 ]; then
        log "Waiting 5 seconds before retry..."
        sleep 5
    fi

done


#
# Failure diagnostics.
#
log "ERROR: wlan0 still not found"

log "===== UPTIME ====="
cat /proc/uptime >> "$LOGFILE" 2>&1

log "===== BOOT STATE ====="
echo "sys.boot_completed=$(getprop sys.boot_completed)" >> "$LOGFILE"
echo "cnss-daemon=$(getprop init.svc.cnss-daemon)" >> "$LOGFILE"
echo "vendor.cnss_diag=$(getprop init.svc.vendor.cnss_diag)" >> "$LOGFILE"

log "===== MODULES ====="
grep -Ei 'qca|cnss|wlan|mhi' /proc/modules >> "$LOGFILE" 2>&1

log "===== NETWORK ====="
ip link >> "$LOGFILE" 2>&1

log "===== CNSS ====="
ls -la "$CNSS_DEVICE_PATH" >> "$LOGFILE" 2>&1

log "===== DMESG ====="
dmesg | grep -Ei \
    'cnss|qca|wlan|wlfw|mhi|pcie|pci link|calibration' \
    | tail -n 300 >> "$LOGFILE" 2>&1

exit 1