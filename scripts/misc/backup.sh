#!/usr/bin/env bash

# Backups your running system via rsync into a image file containing boot and root partition.
# Automatable in headless units. Backup always to an usb-stick or network-share, not into the same filesystem!

set -e

# check sudo
if [ $(id -u) -ne 0 ]; then
    echo "Please run script as root or with sudo!"
    exit 1
fi

# check args
if [ -z "$1" ]; then
    echo "USAGE: pibackup.sh <imagefile>"
    exit 1
fi

IMGFILE=$1


# Prüfe, ob Datei vorhanden ist
if [ ! -f "$IMGFILE" ]; then

    # Lege Datei an, prüfe ob Datei auf dem selben FileSystem ist. Das ist nicht erlaubt.
    echo "checking imgfile filesystem..."
    touch $IMGFILE
    ROOT_FS=$(stat -c "%d" /)
    IMGFILE_FS=$(stat -c "%d" $IMGFILE)

    if [ $ROOT_FS == $IMGFILE_FS ]; then
        echo "$IMGFILE is on same filesystem. this is not allowed"
        exit 1
    fi

    echo "calculating needed size..."
    SIZE=$(df / /boot | tail -n +2 | tr -s ' ' | cut -d ' ' -f 3 | awk '{ SUM += $1} END { print SUM }')
    let SIZE*=150
    let SIZE/=100
    let SIZE/=1024
    let SIZE+=100

    # Erstelle leeres Image
    # siehe hier: https://superuser.com/questions/518554/how-do-you-create-and-partition-a-raw-disk-image
    #dd if=/dev/zero of=/tmp/ram/image.img iflag=fullblock bs=1M count=100 && sync
    echo "creating sparse file $IMGFILE with $SIZE mb..."
    echo "this may take a while..."
    dd if=/dev/zero of=$IMGFILE bs=1024k seek=$SIZE count=0
    parted $IMGFILE mklabel msdos
    parted $IMGFILE mkpart primary fat32 4194304B 272629759B
    parted $IMGFILE -- mkpart primary ext2 272629760B -1S
    parted $IMGFILE print

    # Loop Device erstellen und merken
    echo "creating loop device for $IMGFILE..."
    LOOP=$(losetup -P --find --show $IMGFILE)

    # Paritionen formatieren
    echo "formatting partitions..."
    mkfs.fat "${LOOP}p1"
    mkfs.ext4 "${LOOP}p2"
    fdisk -l $LOOP

    # Loop Device aushängen
    echo "detaching loop device..."
    losetup -d $LOOP
else
    echo "Image $IMGFILE found, incremental backup..."
    echo ""
fi


# Daten kopieren

# Loop Device erstellen und merken
echo "creating loop device for $IMGFILE..."
LOOP=$(losetup -P --find --show $IMGFILE)

# Boot-Part einmounten und sichern
echo "sync boot partition..."
mkdir -p /tmp/imgbak_p1
mount "${LOOP}p1" /tmp/imgbak_p1

rsync -axHAWX --numeric-ids --info=progress2 --delete \
    /boot/ /tmp/imgbak_p1/


# Root-Part einmounten
echo "sync root partition..."
mkdir -p /tmp/imgbak_p2
mount "${LOOP}p2" /tmp/imgbak_p2

# Root-Daten kopieren
rsync -axHAWX --numeric-ids --info=progress2 --delete \
    --exclude="$IMGFILE" \
    / /tmp/imgbak_p2/

# Fix UUIDs
echo "Fixing UUIDs..."
blkid $IMGFILE
UUID=$(blkid -o value $IMGFILE | head -n 1)
echo "Setting UUID $UUID to /etc/fstab..."
sed -i -E s/PARTUUID=[[:alnum:]]+/PARTUUID=$UUID/ /tmp/imgbak_p2/etc/fstab

# CMD-Line auf ersten Start vorbereiten
echo "Writing initial bootline to /boot/cmdline.txt"
echo "console=serial0,115200 console=tty1 root=PARTUUID=$UUID-02 rootfstype=ext4 elevator=deadline fsck.repair=yes rootwait init=/usr/lib/raspi-config/init_resize.sh" > /tmp/imgbak_p1/cmdline.txt

# unmount, remove dirs
echo "unmounting, cleaning up..."
umount /tmp/imgbak_p{1,2}
rmdir /tmp/imgbak_p*

# Loop Device aushängen
echo "detaching loop device..."
losetup -d $LOOP

echo "done:"
echo $IMGFILE