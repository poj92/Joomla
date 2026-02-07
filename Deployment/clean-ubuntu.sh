#!/bin/bash

#############################################################################
# Joomla Cleanup / OS Wipe Script for Ubuntu
# - Option 1: Remove existing Joomla installations and related configs
# - Option 2: Wipe the OS disk (destructive)
#############################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() {
	echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
	echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
	echo -e "${RED}[ERROR]${NC} $1"
}

require_root() {
	if [[ ${EUID} -ne 0 ]]; then
		print_error "Please run this script as root or with sudo."
		exit 1
	fi
}

detect_root_disk() {
	local root_src
	root_src=$(findmnt -no SOURCE / 2>/dev/null || true)
	if [[ -z "${root_src}" ]]; then
		return 1
	fi

	if [[ "${root_src}" == /dev/* ]]; then
		local root_type
		root_type=$(lsblk -no TYPE "${root_src}" 2>/dev/null | head -n 1 || true)
		if [[ "${root_type}" == "part" ]]; then
			local parent
			parent=$(lsblk -no PKNAME "${root_src}" 2>/dev/null | head -n 1 || true)
			if [[ -n "${parent}" ]]; then
				echo "/dev/${parent}"
				return 0
			fi
		elif [[ "${root_type}" == "disk" ]]; then
			echo "${root_src}"
			return 0
		fi
	fi

	return 1
}

confirm_or_exit() {
	local prompt=$1
	local expected=$2
	local input

	read -r -p "${prompt}: " input
	if [[ "${input}" != "${expected}" ]]; then
		print_error "Confirmation failed. Aborting."
		exit 1
	fi
}

cleanup_joomla() {
	print_info "Searching for Joomla installations under /var/www..."
	mapfile -d '' -t joomla_configs < <(find /var/www -maxdepth 3 -type f -name configuration.php -print0 2>/dev/null || true)

	if [[ ${#joomla_configs[@]} -eq 0 ]]; then
		print_warn "No Joomla installations detected under /var/www."
	else
		declare -a joomla_dirs=()
		for config_file in "${joomla_configs[@]}"; do
			joomla_dirs+=("$(dirname "${config_file}")")
		done

		print_warn "The following Joomla directories will be removed:"
		for dir in "${joomla_dirs[@]}"; do
			echo "  - ${dir}"
		done

		confirm_or_exit "Type REMOVE-JOOMLA to confirm" "REMOVE-JOOMLA"

		for dir in "${joomla_dirs[@]}"; do
			rm -rf "${dir}"
		done

		print_info "Joomla directories removed."
	fi

	if [[ -d /etc/apache2/sites-available ]]; then
		print_info "Cleaning Apache virtual host configs pointing to /var/www..."
		mapfile -t site_confs < <(grep -rl "DocumentRoot /var/www" /etc/apache2/sites-available 2>/dev/null || true)
		if [[ ${#site_confs[@]} -gt 0 ]]; then
			for conf in "${site_confs[@]}"; do
				local site_name
				site_name=$(basename "${conf}")
				a2dissite "${site_name}" >/dev/null 2>&1 || true
				rm -f "${conf}"
				rm -f "/etc/apache2/sites-enabled/${site_name}" || true
			done
			systemctl reload apache2 >/dev/null 2>&1 || true
			print_info "Apache site configs removed and Apache reloaded."
		else
			print_warn "No Apache site configs found referencing /var/www."
		fi
	fi

	if [[ -f /root/.joomla_db_credentials ]]; then
		print_info "Found /root/.joomla_db_credentials."
		local mysql_root_pass db_name db_user
		mysql_root_pass=$(awk -F': ' '/MySQL Root Password:/ {print $2}' /root/.joomla_db_credentials | head -n 1 || true)
		db_name=$(awk -F': ' '/Joomla Database:/ {print $2}' /root/.joomla_db_credentials | head -n 1 || true)
		db_user=$(awk -F': ' '/Joomla DB User:/ {print $2}' /root/.joomla_db_credentials | head -n 1 || true)

		if [[ -n "${mysql_root_pass}" && -n "${db_name}" && -n "${db_user}" ]]; then
			print_warn "Dropping Joomla database and user: ${db_name} / ${db_user}"
			mysql -u root -p"${mysql_root_pass}" -e "DROP DATABASE IF EXISTS ${db_name}; DROP USER IF EXISTS '${db_user}'@'localhost'; FLUSH PRIVILEGES;" || true
			rm -f /root/.joomla_db_credentials
			print_info "Database and user removed. Credentials file deleted."
		else
			print_warn "Credentials file is incomplete; skipping DB cleanup."
		fi
	else
		print_warn "No credentials file found; skipping DB cleanup."
	fi

	print_info "Joomla cleanup completed."
}

wipe_os() {
	print_warn "You chose to wipe the OS disk. This is destructive and irreversible."
	print_warn "The system may become unbootable immediately after this step."

	local disk
	disk=$(detect_root_disk || true)
	if [[ -z "${disk}" ]]; then
		read -r -p "Enter the disk device to wipe (e.g., /dev/sda): " disk
	fi

	if [[ ! -b "${disk}" ]]; then
		print_error "${disk} is not a valid block device."
		exit 1
	fi

	print_warn "Target disk: ${disk}"
	confirm_or_exit "Type WIPE-OS to confirm" "WIPE-OS"
	confirm_or_exit "Type the exact disk path to confirm" "${disk}"

	swapoff -a >/dev/null 2>&1 || true
	sync

	print_info "Wiping disk signatures..."
	wipefs -a "${disk}" || true

	print_info "Overwriting the first 100MB to destroy partition table..."
	dd if=/dev/zero of="${disk}" bs=1M count=100 status=progress || true
	sync

	print_info "Disk wipe initiated for ${disk}. Power off or reboot to continue."
}

require_root

print_info "==============================================="
print_info "  Joomla Cleanup / OS Wipe Script for Ubuntu"
print_info "==============================================="
echo
print_info "Choose an action:"
echo "  1) Remove existing Joomla installations"
echo "  2) Wipe the OS disk (destructive)"
echo "  3) Cancel"

read -r -p "Enter choice [1-3]: " action

case "${action}" in
	1)
		cleanup_joomla
		;;
	2)
		wipe_os
		;;
	3)
		print_info "Cancelled."
		;;
	*)
		print_error "Invalid choice."
		exit 1
		;;
esac
