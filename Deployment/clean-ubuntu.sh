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
	declare -a domains_to_clean=()
	
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
			# Extract domain name from path for later SSL cleanup
			local domain_name=$(basename "${dir}")
			domains_to_clean+=("${domain_name}")
		done

		confirm_or_exit "Type REMOVE-JOOMLA to confirm" "REMOVE-JOOMLA"

		for dir in "${joomla_dirs[@]}"; do
			rm -rf "${dir}"
		done

		print_info "Joomla directories removed."
	fi

	# Clean up Apache configurations
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

	# Clean up Apache log files
	print_info "Cleaning Apache log files for removed domains..."
	for domain in "${domains_to_clean[@]}"; do
		rm -f /var/log/apache2/${domain}*.log* 2>/dev/null || true
	done

	# Clean up Let's Encrypt certificates
	print_info "Cleaning Let's Encrypt certificates..."
	for domain in "${domains_to_clean[@]}"; do
		if [[ -d /etc/letsencrypt/renewal ]]; then
			rm -f /etc/letsencrypt/renewal/${domain}.conf 2>/dev/null || true
			rm -f /etc/letsencrypt/renewal/www.${domain}.conf 2>/dev/null || true
		fi
		if [[ -d /etc/letsencrypt/live ]]; then
			rm -rf /etc/letsencrypt/live/${domain} 2>/dev/null || true
			rm -rf /etc/letsencrypt/live/www.${domain} 2>/dev/null || true
		fi
		if [[ -d /etc/letsencrypt/archive ]]; then
			rm -rf /etc/letsencrypt/archive/${domain} 2>/dev/null || true
			rm -rf /etc/letsencrypt/archive/www.${domain} 2>/dev/null || true
		fi
	done

	# Clean up database
	if [[ -f /root/.joomla_db_credentials ]]; then
		print_info "Found /root/.joomla_db_credentials."
		local mysql_root_pass db_name db_user
		mysql_root_pass=$(awk -F': ' '/MySQL Root Password:/ {print $2}' /root/.joomla_db_credentials | head -n 1 || true)
		db_name=$(awk -F': ' '/Joomla Database:/ {print $2}' /root/.joomla_db_credentials | head -n 1 || true)
		db_user=$(awk -F': ' '/Joomla DB User:/ {print $2}' /root/.joomla_db_credentials | head -n 1 || true)

		if [[ -n "${mysql_root_pass}" && -n "${db_name}" && -n "${db_user}" ]]; then
			print_warn "Dropping Joomla database and user: ${db_name} / ${db_user}"
			mysql -u root -p"${mysql_root_pass}" -e "DROP DATABASE IF EXISTS ${db_name}; DROP USER IF EXISTS '${db_user}'@'localhost'; FLUSH PRIVILEGES;" || true
			print_info "Database and user removed."
		else
			print_warn "Credentials file is incomplete; skipping DB cleanup."
		fi
	else
		print_warn "No credentials file found at /root/.joomla_db_credentials"
		# Try to clean up via socket auth if no credentials found
		if systemctl is-active --quiet mysql 2>/dev/null; then
			print_info "Attempting database cleanup via socket authentication..."
			sudo mysql -e "DROP DATABASE IF EXISTS joomla_db; DROP USER IF EXISTS 'joomla_user'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null || true
		fi
	fi

	# Remove all Joomla-related credential files
	print_info "Removing credential files..."
	rm -f /root/.joomla* 2>/dev/null || true

	# Clean up temporary files
	print_info "Cleaning temporary files..."
	rm -f /tmp/joomla*.zip 2>/dev/null || true
	rm -rf /tmp/joomla_* 2>/dev/null || true

	# Clean up PHP sessions (optional - only if you want to clear all sessions)
	if [[ -d /var/lib/php/sessions ]]; then
		print_info "Cleaning PHP session files..."
		find /var/lib/php/sessions -type f -name 'sess_*' -mtime +1 -delete 2>/dev/null || true
	fi

	# Offer to purge MySQL entirely
	echo
	read -r -p "Do you want to completely reset MySQL (remove all databases)? [y/N]: " reset_mysql
	if [[ "${reset_mysql}" =~ ^[Yy]$ ]]; then
		print_warn "This will stop MySQL, remove all data, and reinitialize the database."
		confirm_or_exit "Type RESET-MYSQL to confirm" "RESET-MYSQL"
		
		systemctl stop mysql 2>/dev/null || true
		rm -rf /var/lib/mysql/* 2>/dev/null || true
		mysqld --initialize-insecure --user=mysql 2>/dev/null || true
		systemctl start mysql 2>/dev/null || true
		print_info "MySQL completely reset with empty databases."
	fi

	print_info "Joomla cleanup completed - all residual files removed."
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
