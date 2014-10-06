#!/bin/bash -e

REPO="${1:-centos7}"
TAG="$(date +%Y%m%d)"
BUILDROOT_DIR="${PWD}/buildroot"
YUM_CONF_DIR="${BUILDROOT_DIR}/etc/yum.repos.d"

RPMS=(
    bind-utils
    bash
    yum-utils
    centos-release
    shadow-utils
    initscripts
)

# requires root effective permissions
if [[ $(id -u) -ne 0 ]] ; then
    echo "Error: ${0} must execute as root."
    exit 1
fi

# check if an image with the same repo + tag combination is already registered with docker
if [[ $(docker images | awk '$1 == "'"${REPO}"'" && $2 == "'"${TAG}"'"') ]] ; then
    echo "Error: docker image REPOSITORY:${REPO} TAG:${TAG} exists."
    exit 1
fi

# setup directories
rm -rf ${BUILDROOT_DIR}
mkdir -p ${YUM_CONF_DIR}

# create devices
mkdir ${BUILDROOT_DIR}/dev
mknod -m 600 ${BUILDROOT_DIR}/dev/console c 5 1
mknod -m 600 ${BUILDROOT_DIR}/dev/initctl p
mknod -m 666 ${BUILDROOT_DIR}/dev/full c 1 7
mknod -m 666 ${BUILDROOT_DIR}/dev/null c 1 3
mknod -m 666 ${BUILDROOT_DIR}/dev/ptmx c 5 2
mknod -m 666 ${BUILDROOT_DIR}/dev/random c 1 8
mknod -m 666 ${BUILDROOT_DIR}/dev/tty c 5 0
mknod -m 666 ${BUILDROOT_DIR}/dev/tty0 c 4 0
mknod -m 666 ${BUILDROOT_DIR}/dev/urandom c 1 9
mknod -m 666 ${BUILDROOT_DIR}/dev/zero c 1 5

# create yum configuration
cat > ${BUILDROOT_DIR}/etc/yum.conf << __YUM_CONF__
[main]
cachedir=/var/cache/yum/
keepcache=0
debuglevel=2
logfile=/var/log/yum.log
exactarch=1
gpgcheck=1
plugins=1
tsflags=nodocs
__YUM_CONF__

# create build yum repo file
cat > ${YUM_CONF_DIR}/build.repo << __BUILD_REPO__
[base]
name=CentOS-7 - Base
baseurl=https://mirrors.kernel.org/centos/7/os/x86_64/
gpgkey=https://mirrors.kernel.org/centos/RPM-GPG-KEY-CentOS-7
 
[updates]
name=CentOS-7 - Updates
baseurl=https://mirrors.kernel.org/centos/7/updates/x86_64/
gpgkey=https://mirrors.kernel.org/centos/RPM-GPG-KEY-CentOS-7

[fasttrack]
name=CentOS-7 - Fasttrack
baseurl=https://mirrors.kernel.org/centos/7/fasttrack/x86_64/
gpgkey=https://mirrors.kernel.org/centos/RPM-GPG-KEY-CentOS-7
__BUILD_REPO__

# install packages
yum --installroot=${BUILDROOT_DIR} install ${RPMS[@]} --config=${BUILDROOT_DIR}/etc/yum.conf --assumeyes

# enable centos fasttrack repo
sed -i 's/enabled=0/enabled=1/g' ${BUILDROOT_DIR}/etc/yum.repos.d/CentOS-fasttrack.repo

# configure network
cat > ${BUILDROOT_DIR}/etc/sysconfig/network << __NET_CONF__
NETWORKING=yes
__NET_CONF__

# configure timezone
chroot ${BUILDROOT_DIR} ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime

# configure systemd
chroot ${BUILDROOT_DIR} systemctl mask dev-mqueue.mount
chroot ${BUILDROOT_DIR} systemctl mask dev-hugepages.mount
chroot ${BUILDROOT_DIR} systemctl mask systemd-remount-fs.service
chroot ${BUILDROOT_DIR} systemctl mask sys-kernel-config.mount
chroot ${BUILDROOT_DIR} systemctl mask sys-kernel-debug.mount
chroot ${BUILDROOT_DIR} systemctl mask sys-fs-fuse-connections.mount
chroot ${BUILDROOT_DIR} systemctl mask display-manager.service
chroot ${BUILDROOT_DIR} systemctl disable graphical.target
chroot ${BUILDROOT_DIR} systemctl enable multi-user.target

cat > ${BUILDROOT_DIR}/etc/systemd/system/dbus.service << __DBUS_CONF__
[Unit]
Description=D-Bus System Message Bus
Requires=dbus.socket
After=syslog.target
 
[Service]
PIDFile=/var/run/messagebus.pid
ExecStartPre=/bin/mkdir -p /var/run/dbus
ExecStartPre=/bin/chmod g+w /var/run/ /var/run/dbus/
ExecStart=/bin/dbus-daemon --system --fork
ExecReload=/bin/dbus-send --print-reply --system --type=method_call --dest=org.freedesktop.DBus / org.freedesktop.DBus.ReloadConfig
ExecStopPost=/bin/rm -f /var/run/messagebus.pid
User=dbus
Group=root
PermissionsStartOnly=true
__DBUS_CONF__

# delete yum build repo and clean
rm -f ${YUM_CONF_DIR}/build.repo
yum --installroot=${BUILDROOT_DIR} clean all
rm -rf ${BUILDROOT_DIR}/var/cache/yum/*

# delete ldconfig
rm -rf ${BUILDROOT_DIR}/etc/ld.so.cache
rm -rf ${BUILDROOT_DIR}/var/cache/ldconfig/*

# delete logs
find ${BUILDROOT_DIR}/var/log -type f -delete

# reduce size of locale files
chroot ${BUILDROOT_DIR} localedef --delete-from-archive $(localedef --list-archive | grep -v "en_US" | xargs)
mv ${BUILDROOT_DIR}/usr/lib/locale/locale-archive ${BUILDROOT_DIR}/usr/lib/locale/locale-archive.tmpl
chroot ${BUILDROOT_DIR} /usr/sbin/build-locale-archive
:>${BUILDROOT_DIR}/usr/lib/locale/locale-archive.tmpl
find ${BUILDROOT_DIR}/usr/{{lib,share}/locale,bin/localedef} -type f | grep -v "en_US" | xargs rm

# delete non-utf character sets
find ${BUILDROOT_DIR}/usr/lib64/gconv/ -type f ! -name "UTF*" -delete

# delete docs
find ${BUILDROOT_DIR}/usr/share/{man,doc,info,gnome} -type f -delete

# delete i18n
find ${BUILDROOT_DIR}/usr/share/i18n -type f -delete

# delete cracklib
find ${BUILDROOT_DIR}/usr/share/cracklib -type f -delete

# delete timezones
find ${BUILDROOT_DIR}/usr/share/zoneinfo -type f \( ! -name "Etc" ! -name "UTC" \) -delete

# delete /boot
rm -rf ${BUILDROOT_DIR}/boot

# delete sln
rm -f ${BUILDROOT_DIR}/sbin/sln

# inject build aka tag number
echo ${TAG} > ${BUILDROOT_DIR}/.build

# create and register image with docker
tar --numeric-owner --acls --xattrs --selinux -C ${BUILDROOT_DIR} -c . | docker import - ${REPO}

# run simple test
docker run -i -t ${REPO} echo "${REPO} built successfully."

# tag image
IMAGE_ID="$(docker images | grep ${REPO} | awk '{print $3}' | head -1)"
docker tag ${IMAGE_ID} ${REPO}:${TAG}
docker tag ${IMAGE_ID} ${REPO}:latest

echo "Completed in ${SECONDS} seconds."

# EOF
