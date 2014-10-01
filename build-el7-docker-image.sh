#!/bin/bash -e

DIST="centos7"
BUILD="$(date +%Y%m%d)"
IMG_DIR="${PWD}/buildroot-${DIST}"
REPO_DIR="${IMG_DIR}/etc/yum.repos.d"

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

# check if an image with the same distro + version combination is already registered with docker
if [[ $(docker images | awk '$1 == "'"${DIST}"'" && $2 == "'"${BUILD}"'"') ]] ; then
    echo "Error: docker image REPOSITORY:${DIST} BUILD:${BUILD} exists."
    exit 1
fi

# setup directories
rm -rf ${IMG_DIR}
mkdir -p ${REPO_DIR}

# create devices
mkdir ${IMG_DIR}/dev
mknod -m 600 ${IMG_DIR}/dev/console c 5 1
mknod -m 600 ${IMG_DIR}/dev/initctl p
mknod -m 666 ${IMG_DIR}/dev/full c 1 7
mknod -m 666 ${IMG_DIR}/dev/null c 1 3
mknod -m 666 ${IMG_DIR}/dev/ptmx c 5 2
mknod -m 666 ${IMG_DIR}/dev/random c 1 8
mknod -m 666 ${IMG_DIR}/dev/tty c 5 0
mknod -m 666 ${IMG_DIR}/dev/tty0 c 4 0
mknod -m 666 ${IMG_DIR}/dev/urandom c 1 9
mknod -m 666 ${IMG_DIR}/dev/zero c 1 5

# create yum configuration
cat > ${IMG_DIR}/etc/yum.conf << __YUM_CONF__
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
cat > ${REPO_DIR}/build.repo << __BUILD_REPO__
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
yum --installroot=${IMG_DIR} install ${RPMS[@]} --config=${IMG_DIR}/etc/yum.conf --assumeyes

# enable centos fasttrack repo
sed -i 's/enabled=0/enabled=1/g' ${IMG_DIR}/etc/yum.repos.d/CentOS-fasttrack.repo

# configure network
cat > ${IMG_DIR}/etc/sysconfig/network << __NET_CONF__
NETWORKING=yes
__NET_CONF__

# configure timezone
chroot ${IMG_DIR} ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime

# configure systemd
chroot ${IMG_DIR} systemctl mask dev-mqueue.mount
chroot ${IMG_DIR} systemctl mask dev-hugepages.mount
chroot ${IMG_DIR} systemctl mask systemd-remount-fs.service
chroot ${IMG_DIR} systemctl mask sys-kernel-config.mount
chroot ${IMG_DIR} systemctl mask sys-kernel-debug.mount
chroot ${IMG_DIR} systemctl mask sys-fs-fuse-connections.mount
chroot ${IMG_DIR} systemctl mask display-manager.service
chroot ${IMG_DIR} systemctl disable graphical.target
chroot ${IMG_DIR} systemctl enable multi-user.target

cat > ${IMG_DIR}/etc/systemd/system/dbus.service << __DBUS_CONF__
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
rm -f ${REPO_DIR}/build.repo
yum --installroot=${IMG_DIR} clean all
rm -rf ${IMG_DIR}/var/cache/yum/*

# delete ldconfig
rm -rf ${IMG_DIR}/etc/ld.so.cache
rm -rf ${IMG_DIR}/var/cache/ldconfig/*

# delete logs
find ${IMG_DIR}/var/log -type f -delete

# reduce size of locale files
chroot ${IMG_DIR} localedef --delete-from-archive $(localedef --list-archive | grep -v "en_US" | xargs)
mv ${IMG_DIR}/usr/lib/locale/locale-archive ${IMG_DIR}/usr/lib/locale/locale-archive.tmpl
chroot ${IMG_DIR} /usr/sbin/build-locale-archive
:>${IMG_DIR}/usr/lib/locale/locale-archive.tmpl
find ${IMG_DIR}/usr/{{lib,share}/locale,bin/localedef} -type f | grep -v "en_US" | xargs rm

# delete non-utf character sets
find ${IMG_DIR}/usr/lib64/gconv/ -type f ! -name "UTF*" -delete

# delete docs
find ${IMG_DIR}/usr/share/{man,doc,info,gnome} -type f -delete

# delete i18n
find ${IMG_DIR}/usr/share/i18n -type f -delete

# delete cracklib
find ${IMG_DIR}/usr/share/cracklib -type f -delete

# delete timezones
find ${IMG_DIR}/usr/share/zoneinfo -type f \( ! -name "Etc" ! -name "UTC" \) -delete

# delete /boot
rm -rf ${IMG_DIR}/boot

# delete sln
rm -f ${IMG_DIR}/sbin/sln

# inject build number
echo ${BUILD} > ${IMG_DIR}/.build 

# create and register image with docker
tar --numeric-owner --acls --xattrs --selinux -C ${IMG_DIR} -c . | docker import - ${DIST} ${BUILD}

# run simple test
docker run -i -t ${DIST}:${BUILD} echo "${DIST}:${BUILD} built successfully."

echo "Completed in ${SECONDS} seconds."

# EOF
