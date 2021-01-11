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
		"--prefix             DEFAULT: $(whoami), the prefix to use for kube node names" \
		"--masters            DEFAULT: 1, the number of master nodes to create (min: 1, max: 50)" \
		"--workers            DEFAULT: 1, the number of worker nodes to create (min: 1, max: 50)" \
		"--os-version         DEFAULT: 7, the version of CentOS to use" \
		"" \
		"--cpu                DEFAULT: 2, the number of CPUs for each node" \
		"--memory             DEFAULT: 4096, the amount of memory to allocate for each node" \
		"" \
		"--network            DEFAULT: bridge, the network for bridging VMs within qemu" \
		"--domain             DEFAULT: local, the dns domain used to register IPs" \
		"" \
		"NOTE: ONLY THE LAST OCTET OF THE IP ADDRESSES ARE INCREMENTED, PLEASE ENSURE THERE IS ENOUGH IPS AVAILABLE" \
		"" \
		"--gh-user            DEFAULT: tiffanywang3, the github username used to retrieve SSH keys." \
		"                     This can be specified multiple times"
	print_fail \
		"" \
		"Example:" \
		"" \
		"./kvm.sh --masters 3 --workers 3 --cpu 4 --memory 8192 --gh-user somebody"
}

PREFIX=$(whoami)-
NETWORK="bridge"

MASTER_NODE_COUNT=1
WORKER_NODE_COUNT=1

CENTOS_VERSION=7
CPU_LIMIT=2
MEMORY_LIMIT=4096

while [ $# -gt 0 ]; do
	case $1 in
		--prefix)
			PREFIX="$2"-
			shift
			;;
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
		--domain)
			DOMAIN=$2
			shift
			;;
		--gh-user)
			GH_USER="$2 $GH_USER"
			shift
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
for node in $(sudo virsh list --all --name | grep "kube-${PREFIX}"); do
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
	printf "  - curl https://github.com/%s.keys >> /home/kube-admin/.ssh/authorized_keys\n" "$user" >> cloud_init.cfg
done

printf "  %s\n"  \
	"- chmod -R u=rwX,g=rX,o= /home/kube-admin/.ssh" \
	"- chown -R kube-admin:kube-admin /home/kube-admin/.ssh" >> cloud_init.cfg

# create a virtual machine
create_vm() {
	hostname=$1

	snapshot=$hostname.qcow2
	init=$hostname-init.img
	metadata=$hostname-metadata
	cloud_cfg=$hostname-cloud_init.cfg
	network_cfg=$hostname-network.cfg

	# copy the cloud_init.cfg
	cp cloud_init.cfg "$cloud_cfg"

	if [ "$hostname" = "kube-${PREFIX}proxy" ]; then
		# modify the cloud_init to include the haproxy.cfg
		cat <<- EOF >> "$cloud_cfg"
		  - systemctl enable haproxy.service
		  - systemctl start haproxy.service

		write_files:
		- path: /etc/haproxy/haproxy.cfg
		  encoding: base64
		  content: $(base64 -w 0 < kube-"${PREFIX}"proxy-haproxy.cfg)
		EOF
	fi

	# create snapshot and increase size to 30GB
	qemu-img create -b "$BASE_IMAGE" -f qcow2 -F qcow2 "$snapshot" 30G
	qemu-img info "$snapshot"

	# insert metadata into init image
	printf "instance-id: %s\n" "$(uuidgen || printf i-abcdefg)" > "$metadata"
	printf "local-hostname: %s\n" "$hostname" >> "$metadata"
	printf "hostname: %s.%s\n" "$hostname" "$DOMAIN" >> "$metadata"

	# create the network config
	cp network.cfg.template "$network_cfg"

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
		--network network:default \
		--network network:"$NETWORK" \
		--autostart \
		--noautoconsole

	# set the timeout
	sudo virsh guest-agent-timeout "$hostname" --timeout 60
}

: $((i=1))
while [ $((i<=MASTER_NODE_COUNT)) -ne 0 ]; do
	create_vm kube-"${PREFIX}"master-"$(printf "%02d" "$i")"
	: $((i=i+1))
done

: $((i=1))
while [ $((i<=WORKER_NODE_COUNT)) -ne 0 ]; do
	create_vm kube-"${PREFIX}"worker-"$(printf "%02d" "$i")"
	: $((i=i+1))
done

# create the haproxy config
cp haproxy.cfg.template kube-"${PREFIX}"proxy-haproxy.cfg

# iterate over each master node
: $((i=1))
while [ $((i<=MASTER_NODE_COUNT)) -ne 0 ]; do
	name=kube-"$PREFIX"master-$(printf "%02d" "$i")

	until sudo virsh domifaddr --domain "$name" --source agent 2>/dev/null | grep -w eth0 | grep -w ipv4 1>/dev/null; do
		print_warn "waiting for $name : eth0..."
		sleep 5
	done

	vip=$(sudo virsh domifaddr --domain "$name" --source agent | grep -w eth0 | grep -E -o '([[:digit:]]{1,3}\.){3}[[:digit:]]{1,3}')

	# add the ip to the haproxy config
	printf "    server %s %s:6443 check\n" "$name" "$vip" >> kube-"${PREFIX}"proxy-haproxy.cfg
	: $((i=i+1))
done

# create the ha proxy node
create_vm kube-"${PREFIX}"proxy "$PROXY_VIRTUAL_IP" "$PROXY_MAC" "$PROXY_IP"

print_machines() {
	role=$1
	count=$2

	: $((i=1))
	while [ $((i<=count)) -ne 0 ]; do
		name=kube-"$PREFIX""$role"-$(printf "%02d" "$i")

		until sudo virsh domifaddr --domain "$name" --source agent 2>/dev/null | grep -w eth0 | grep -w ipv4 1>/dev/null; do
			sleep 5
		done

		until sudo virsh domifaddr --domain "$name" --source agent 2>/dev/null | grep -w eth1 | grep -w ipv4 1>/dev/null; do
			sleep 5
		done

		private_ip=$(sudo virsh domifaddr --domain "$name" --source agent | grep -w eth0 | grep -E -o '([[:digit:]]{1,3}\.){3}[[:digit:]]{1,3}')
		public_ip=$(sudo virsh domifaddr --domain "$name" --source agent | grep -w eth1 | grep -E -o '([[:digit:]]{1,3}\.){3}[[:digit:]]{1,3}')

		printf "  - name: %s\n    role: %s\n    privateAddress: %s\n    publicAddress: %s\n" \
			"$name" \
			"$role" \
			"$private_ip" \
			"$public_ip"

		: $((i=i+1))
	done
}

print_success "The following nodes have been configured:" ""

printf "machines:\n"
print_machines master "$MASTER_NODE_COUNT"
printf "\n"
print_machines worker "$WORKER_NODE_COUNT"
