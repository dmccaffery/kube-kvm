#! /usr/bin/env sh
# shellcheck disable=SC2155

set -e

FORMAT_CLEAR=$(tput sgr0)	# CLEAR ALL FORMAT
FORMAT_BOLD=$(tput bold)	# SET BRIGH

CLR_RED=$(tput setaf 1)		# ANSI RED
CLR_GREEN=$(tput setaf 2)	# ANSI GREEN
CLR_YELLOW=$(tput setaf 3)	# ANSI

CLR_BRIGHT_RED="$FORMAT_BOLD$CLR_RED"		# BRIGHT RED
CLR_BRIGHT_GREEN="$FORMAT_BOLD$CLR_GREEN"	# BRIGHT GREEN
CLR_BRIGHT_YELLOW="$FORMAT_BOLD$CLR_YELLOW"	# BRIGHT

CLR_SUCCESS=$CLR_BRIGHT_GREEN
CLR_WARN=$CLR_BRIGHT_YELLOW
CLR_FAIL=$CLR_BRIGHT_RED

print_success()
{
	printf "${CLR_SUCCESS}%s${FORMAT_CLEAR}\n" "$@"
}

print_warn()
{
	printf "${CLR_WARN}%s${FORMAT_CLEAR}\n" "$@"
}

print_fail()
{
	printf "${CLR_FAIL}%s${FORMAT_CLEAR}\n" "$@" >&2
}

help() {
	print_success \
		"" \
		"KVM Configuration for Kubernetes" \
		"" \
		"Usage: ./kvm.sh [OPTIONS]"
	print_warn \
		"" \
		"Options:" \
		"" \
		"--masters            DEFAULT: 1, the number of master nodes to create (min: 1, max: 50)" \
		"--workers            DEFAULT: 1, the number of worker nodes to create (min: 1, max: 50)" \
		"--os-version         DEFAULT: 7, the version of CentOS to use" \
		"" \
		"--cpu                DEFAULT: 2, the number of CPUs for each node" \
		"--memory             DEFAULT: 4096, the amount of memory to allocate for each node" \
		"" \
		"--network            DEFAULT: bridge, the network for bridging VMs within qemu" \
		"--gateway            DEFAULT: 192.168.50.1, the IP address of the gateway for the network subnet" \
		"--domain             DEFAULT: local, the dns domain used to register IPs" \
		"" \
		"--enable-static-ips  DEFAULT: false, a value indicating whether or not to use static ips" \
		"--proxy-ip           DEFAULT: 192.168.50.100/24, the ip to use for the master load balancer" \
		"--master-ip          DEFAULT: 192.168.50.101/24, the first ip to use for masters (incremented)" \
		"--worker-ip          DEFAULT: 192.168.50.151/24, the first ip to use for workers (incremented)" \
		"" \
		"--proxy-mac-address  DEFAULT: 01:01:01:01:FF, the mac address used for bridge reservations (incremented)" \
		"--master-mac-address DEFAULT: 01:01:01:01:01, the mac address used for bridge reservations (incremented)" \
		"--worker-mac-address DEFAULT: 01:01:01:02:01, the mac address used for bridge reservations (incremented)" \
		"" \
		"--virtual-proxy-ip   DEFAULT: 192.168.60.100/24, the ip to use for the master load balancer" \
		"--virtual-master-ip  DEFAULT: 192.168.60.101/24, the first ip to use for masters (incremented)" \
		"--virtual-worker-ip  DEFAULT: 192.168.60.151/24, the first ip to use for workers (incremented)" \
		"" \
		"NOTE: ONLY THE LAST OCTET OF THE IP ADDRESSES ARE INCREMENTED, PLEASE ENSURE THERE IS ENOUGH IPS AVAILABLE" \
		"" \
		"--gh-user            DEFAULT: tiffanywang3, the github username used to retrieve SSH keys." \
		"                     This can be specified multiple times"
	print_fail \
		"" \
		"Example:" \
		"" \
		"./kvm.sh --masters 3 --workers 3 --cpu 4 --memory 8192 --enable-static-ips --gh-user somebody"
}

NETWORK="bridge"
GATEWAY="192.168.50.1"
DOMAIN="local"

PROXY_IP="192.168.50.100/24"
PROXY_MAC="02:01:01:01:01:FF"
PROXY_VIRTUAL_IP="192.168.60.100/24"

MASTER_NODE_COUNT=1
MASTER_IP="192.168.50.101/24"
MASTER_MAC="02:01:01:01:01:01"
MASTER_VIRTUAL_IP="192.168.60.101/24"

WORKER_NODE_COUNT=1
WORKER_IP="192.168.50.151/24"
WORKER_MAC="02:01:01:01:02:01"
WORKER_VIRTUAL_IP="192.168.60.151/24"

CENTOS_VERSION=7
CPU_LIMIT=2
MEMORY_LIMIT=4096

ENABLE_STATIC_IPS=
ENABLE_HOST_DHCP=false

while [ $# -gt 0 ]; do
	case $1 in
		--masters)
			MASTER_NODE_COUNT=$2
			shift
			;;
		--workers)
			WORKER_NODE_COUNT=$2
			shift
			;;
		--os-version)
			CENTOS_VERSION=$2
			shift
			;;
		--cpu)
			CPU_LIMIT=$2
			shift
			;;
		--memory)
			MEMORY_LIMIT=$2
			shift
			;;
		--network)
			NETWORK=$2
			shift
			;;
		--gateway)
			GATEWAY=$2
			shift
			;;
		--domain)
			DOMAIN=$2
			shift
			;;
		--gh-user)
			GH_USER="$2 $GH_USER"
			shift
			;;
		--proxy-mac-address)
			PROXY_MAC=$2
			shift
			;;
		--proxy-ip)
			PROXY_IP=$2
			shift
			;;
		--proxy-virtual-ip)
			PROXY_VIRTUAL_IP=$2
			shift
			;;
		--master-mac-address)
			MASTER_MAC=$2
			shift
			;;
		--master-ip)
			MASTER_IP=$2
			shift
			;;
		--master-virtual-ip)
			MASTER_VIRTUAL_IP=$2
			shift
			;;
		--worker-mac-address)
			WORKER_MAC=$2
			shift
			;;
		--worker-ip)
			WORKER_IP=$2
			shift
			;;
		--worker-virtual-ip)
			WORKER_VIRTUAL_IP=$2
			shift
			;;
		--enable-static-ips)
			ENABLE_STATIC_IPS=1
			;;
		--help)
			help
			exit 0
			;;
		*)
			printf "unknown option: %s\n\n" "$1"
			help
			exit 1
			;;
	esac
	shift
done

# default the gh user if unspecified
if [ -z "$GH_USER" ]; then
	GH_USER=tiffanywang3
fi

# if static ips are not enabled
if [ -z "$ENABLE_STATIC_IPS" ]; then
	# turn on host dhcp
	ENABLE_HOST_DHCP=true

	# clear the ips
	PROXY_IP=
	MASTER_IP=
	WORKER_IP=
fi

increment_ip() {
	value="${1:-}"

	if [ -z "$value" ]; then
		return
	fi

	prefix=${value%.*}
	value=${value##*.}

	octet=${value%/*}
	subnet=${value##*/}

	octet=$((octet+1))

	printf "%s.%s/%s" "$prefix" "$octet" "$subnet"
}

increment_mac() {
	value="${1:-}"

	prefix=${value%:*}
	value=${value##*:}

	value=$((value+1))

	printf "%s:%02d" "$prefix" "$value"
}

OS_VARIANT="centos$CENTOS_VERSION.0"
BASE_IMAGE=CentOS-$CENTOS_VERSION-x86_64-GenericCloud.qcow2

if [ ! -f "$BASE_IMAGE" ]; then
	print_success "Downloading $BASE_IMAGE...."
	wget http://cloud.centos.org/centos/7/images/"$BASE_IMAGE" -O "$BASE_IMAGE"
fi

# install all prerequisites
sudo apt update
sudo apt-get install qemu-kvm libvirt-daemon-system \
	libvirt-clients libnss-libvirt virtinst

# make sure libvirtd is enabled
sudo systemctl enable libvirtd

# add user to libvirt and kvm groups
sudo usermod -a -G libvirt "$USER"
sudo usermod -a -G kvm "$USER"

# delete existing nodes
for node in $(sudo virsh list --all --name | grep "kube-"); do
	sudo virsh shutdown "$node"
	sudo virsh destroy "$node"
	sudo virsh undefine "$node"
done

# remove existing configs
rm -f kube-*

# ensure base image is accessible
sudo chmod u=rw,go=r "$BASE_IMAGE"

# create the cloud-init config
cat cloud_init.cfg.template > cloud_init.cfg

# emit every user key into authorized keys
for user in $GH_USER; do
	printf "  - curl https://github.com/%s.keys | tee -a /home/kube-admin/.ssh/authorized_keys\n" "$user" >> cloud_init.cfg
done

# create a virtual machine
create_vm() {
	hostname=$1
	virtual_ip=$2
	host_mac=$3
	host_ip=${4:-}

	snapshot=$hostname.qcow2
	init=$hostname-init.img
	metadata=$hostname-metadata
	cloud_cfg=$hostname-cloud_init.cfg
	network_cfg=$hostname-network.cfg

	# copy the cloud_init.cfg
	cp cloud_init.cfg "$cloud_cfg"

	if [ "$hostname" = "kube-proxy" ]; then
		# modify the cloud_init to include the haproxy.cfg
		cat <<- EOF >> "$cloud_cfg"
		  - systemctl enable haproxy.service
		  - systemctl start haproxy.service

		write_files:
		- path: /etc/haproxy/haproxy.cfg
		  encoding: base64
		  content: $(base64 -w 0 < kube-proxy-haproxy.cfg)
		EOF
	fi

	# create snapshot and increase size to 30GB
	qemu-img create -b "$BASE_IMAGE" -f qcow2 -F qcow2 "$snapshot" 30G
	qemu-img info "$snapshot"

	# insert metadata into init image
	printf "instance-id: %s\n" "$(uuidgen || printf i-abcdefg)" > "$metadata"
	printf "local-hostname: %s.local\n" "$hostname" >> "$metadata"

	# create the network config
	sed "s@VIRTUAL_IP@$virtual_ip@g" network.cfg.template \
		| sed "s@ENABLE_HOST_DHCP@$ENABLE_HOST_DHCP@g" \
		| sed "s@GATEWAY@$GATEWAY@g" \
		| sed "s@DOMAIN@$DOMAIN@g" \
		| sed "s@HOST_MAC$host_mac@g" \
		| sed "s@HOST_IP@$host_ip@g" > "$network_cfg"

	# setup the cloud-init metadata
	cloud-localds -v --network-config="$network_cfg" "$init" "$cloud_cfg" "$metadata"

	# ensure file permissions belong to kvm group
	sudo chmod ug=rw,o= "$snapshot"
	sudo chown "$USER":kvm "$snapshot" "$init"

	# create the vm
	sudo virt-install --name "$hostname" \
		--virt-type kvm --memory "$MEMORY_LIMIT" --vcpus "$CPU_LIMIT" \
		--boot hd,menu=on \
		--disk path="$init",device=cdrom \
		--disk path="$snapshot",device=disk \
		--graphics vnc \
		--os-type Linux --os-variant "$OS_VARIANT" \
		--network default \
		--network "$NETWORK",mac="$host_mac" \
		--autostart \
		--noautoconsole

	# set the timeout
	sudo virsh guest-agent-timeout "$hostname" --timeout 60
}

: $((i=1))
while [ $((i<=MASTER_NODE_COUNT)) -ne 0 ]; do
	create_vm \
		kube-master-"$(printf "%02d" "$i")" \
		"$MASTER_VIRTUAL_IP" \
		"$MASTER_MAC" \
		"$MASTER_IP"

	# increment the mac and ip
	MASTER_VIRTUAL_IP=$(increment_ip "$MASTER_VIRTUAL_IP")
	MASTER_MAC=$(increment_mac "$MASTER_MAC")
	MASTER_IP=$(increment_ip "$MASTER_IP")
	: $((i=i+1))
done

: $((i=1))
while [ $((i<=WORKER_NODE_COUNT)) -ne 0 ]; do
	create_vm \
		kube-worker-"$(printf "%02d" "$i")" \
		"$WORKER_VIRTUAL_IP" \
		"$WORKER_MAC" \
		"$WORKER_IP"

	# increment the mac and ip
	WORKER_VIRTUAL_IP=$(increment_ip "$WORKER_VIRTUAL_IP")
	WORKER_MAC=$(increment_mac "$WORKER_MAC")
	WORKER_IP=$(increment_ip "$WORKER_IP")
	: $((i=i+1))
done

# wait for nodes to come up; # todo: replace with until / wait
sleep 60

# create the haproxy config
cat haproxy.cfg.template > kube-proxy-haproxy.cfg

# iterate over each master node
: $((i=1))
while [ $((i<=MASTER_NODE_COUNT)) -ne 0 ]; do
	name=kube-master-$(printf "%02d" "$i")
	ip=$(sudo virsh domifaddr --domain "$name" --source agent | grep -w eth1 | grep -E -o '([[:digit:]]{1,3}\.){3}[[:digit:]]{1,3}')

	# add the ip to the haproxy config
	printf "    server %s %s:6443 check\n" "$name" "$ip" >> kube-proxy-haproxy.cfg
	: $((i=i+1))
done

# create the ha proxy node
create_vm kube-proxy "$PROXY_VIRTUAL_IP" "$PROXY_MAC" "$PROXY_IP"
