#!/system/bin/sh
LOGFILE=/data/adb/modules/nothing_phone2_wifi_fix/wifi_fix.log
echo "[$(date)] WiFi fix service started" > $LOGFILE
sleep 15

if [ ! -f "/mnt/vendor/persist/wlan/WCNSS_qcom_cfg.ini" ]; then
    echo "[$(date)] Repairing persist/wlan..." >> $LOGFILE
    mkdir -p /mnt/vendor/persist/wlan
    cp /vendor/etc/wifi/qca6490/WCNSS_qcom_cfg.ini /mnt/vendor/persist/wlan/
    chown -R wifi:wifi /mnt/vendor/persist/wlan/
    chmod 644 /mnt/vendor/persist/wlan/WCNSS_qcom_cfg.ini
    chcon -R u:object_r:wifi_vendor_data_file:s0 /mnt/vendor/persist/wlan/
    echo "[$(date)] persist/wlan repaired" >> $LOGFILE
else
    echo "[$(date)] persist/wlan OK" >> $LOGFILE
fi

CNSS_DEVICE="b0000000.qcom,cnss-qca6490"
CNSS_PATH="/sys/bus/platform/drivers/cnss2"

if [ ! -e "$CNSS_PATH/$CNSS_DEVICE" ]; then
    echo "[$(date)] Binding cnss2..." >> $LOGFILE
    echo "$CNSS_DEVICE" > "$CNSS_PATH/bind" 2>> $LOGFILE
    sleep 3
fi

echo "[$(date)] Loading wlan driver..." >> $LOGFILE
insmod /vendor/lib/modules/qca_cld3_qca6490.ko 2>> $LOGFILE
sleep 3

echo "[$(date)] Triggering fs_ready..." >> $LOGFILE
setenforce 0
echo 1 > "/sys/devices/platform/soc/$CNSS_DEVICE/fs_ready" 2>> $LOGFILE
setenforce 1

for i in $(seq 1 15); do
    sleep 2
    if ip link show wlan0 > /dev/null 2>&1; then
        ip link set wlan0 up
        echo "[$(date)] wlan0 UP after ${i}x2s - SUCCESS!" >> $LOGFILE
        exit 0
    fi
done
echo "[$(date)] ERROR: wlan0 not found" >> $LOGFILE