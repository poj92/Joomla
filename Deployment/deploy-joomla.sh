#!/bin/bash

#############################################################################
# Joomla CMS Deployment Script for Ubuntu
# This script automates the installation of Joomla CMS with SSL
#############################################################################

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_message() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    print_error "Please run this script as root or with sudo"
    exit 1
fi

# Function to validate domain name
validate_domain() {
    local domain=$1
    if [[ ! $domain =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 1
    fi
    return 0
}

# Function to validate email
validate_email() {
    local email=$1
    if [[ ! $email =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 1
    fi
    return 0
}

print_message "==============================================="
print_message "  Joomla CMS Deployment Script for Ubuntu"
print_message "==============================================="
echo

# Prompt for domain name
while true; do
    read -p "Enter your domain name (e.g., example.com): " DOMAIN
    if validate_domain "$DOMAIN"; then
        break
    else
        print_error "Invalid domain name format. Please try again."
    fi
done

# Prompt for admin email
while true; do
    read -p "Enter admin email address: " ADMIN_EMAIL
    if validate_email "$ADMIN_EMAIL"; then
        break
    else
        print_error "Invalid email format. Please try again."
    fi
done

# Prompt for admin username
while true; do
    read -p "Enter Joomla admin username: " ADMIN_USER
    if [ -n "$ADMIN_USER" ]; then
        break
    else
        print_error "Admin username cannot be empty."
    fi
done

# Prompt for admin password
while true; do
    read -sp "Enter Joomla admin password: " ADMIN_PASS
    echo
    if [ ${#ADMIN_PASS} -ge 8 ]; then
        read -sp "Confirm admin password: " ADMIN_PASS_CONFIRM
        echo
        if [ "$ADMIN_PASS" == "$ADMIN_PASS_CONFIRM" ]; then
            break
        else
            print_error "Passwords do not match. Please try again."
        fi
    else
        print_error "Password must be at least 8 characters long."
    fi
done

# Prompt for database credentials
print_message "Setting up database credentials..."
DB_NAME="joomla_db"
DB_USER="joomla_user"
DB_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

echo
print_message "Domain: $DOMAIN"
print_message "Admin Email: $ADMIN_EMAIL"
print_message "Admin Username: $ADMIN_USER"
print_message "Database Name: $DB_NAME"
print_message "Database User: $DB_USER"
echo

read -p "Continue with installation? (y/n): " CONFIRM
if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
    print_error "Installation cancelled."
    exit 0
fi

# Update system
print_message "Updating system packages..."
apt update && apt upgrade -y

# Install prerequisites
apt install -y software-properties-common gnupg2 curl lsb-release ca-certificates unzip wget

# Attempt to add PHP 8.3 repository
print_message "Attempting to add PHP 8.3 repository..."
PHP83_AVAILABLE=false
UBUNTU_CODENAME=$(lsb_release -cs)

# Method 1: Ondrej PPA (Ubuntu)
if add-apt-repository -y ppa:ondrej/php 2>/dev/null; then
    apt update
    if apt-cache show php8.3 &>/dev/null; then
        PHP83_AVAILABLE=true
    fi
fi

# Method 2: Sury repo (Debian/Ubuntu) if Method 1 failed
if [ "$PHP83_AVAILABLE" = false ]; then
    print_message "Trying Sury repository..."
    mkdir -p /usr/share/keyrings
    curl -fsSL https://packages.sury.org/php/apt.gpg -o /usr/share/keyrings/sury-php.gpg 2>/dev/null || true
    echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ ${UBUNTU_CODENAME} main" > /etc/apt/sources.list.d/sury-php.list 2>/dev/null || true
    apt update 2>/dev/null || true
    if apt-cache show php8.3 &>/dev/null; then
        PHP83_AVAILABLE=true
    else
        rm -f /etc/apt/sources.list.d/sury-php.list 2>/dev/null || true
        apt update 2>/dev/null || true
    fi
fi

# Install PHP
if [ "$PHP83_AVAILABLE" = true ]; then
    print_message "Installing PHP 8.3..."
    PHP_VER="8.3"
    apt install -y apache2 mysql-server \
        php${PHP_VER} php${PHP_VER}-mysql php${PHP_VER}-xml php${PHP_VER}-mbstring \
        php${PHP_VER}-zip php${PHP_VER}-gd php${PHP_VER}-curl php${PHP_VER}-intl \
        libapache2-mod-php${PHP_VER} \
        certbot python3-certbot-apache
else
    print_warning "PHP 8.3 repository not available. Installing system default PHP..."
    apt install -y apache2 mysql-server \
        php php-mysql php-xml php-mbstring php-zip php-gd php-curl php-intl \
        libapache2-mod-php \
        certbot python3-certbot-apache
fi

# Detect the installed PHP version
PHP_VER_FULL=$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo "0")
PHP_VER_SHORT=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "0")
print_message "Installed PHP version: ${PHP_VER_FULL}"

# Enable Apache modules
print_message "Enabling Apache modules..."
a2dismod php* 2>/dev/null || true
a2enmod php${PHP_VER_SHORT} 2>/dev/null || true
a2enmod rewrite
a2enmod ssl
a2enmod headers

# Set installed PHP as default CLI version
update-alternatives --set php /usr/bin/php${PHP_VER_SHORT} 2>/dev/null || true

# Start and enable services
print_message "Starting services..."
systemctl start apache2
systemctl enable apache2
systemctl start mysql
systemctl enable mysql

# Secure MySQL installation and create database
print_message "Configuring MySQL database..."
MYSQL_ROOT_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

# Use socket auth via sudo for the entire setup to avoid password auth issues
sudo mysql <<EOF
-- Set root password
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASS}';
FLUSH PRIVILEGES;

-- Secure installation
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';

-- Create Joomla database and user
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# Save database credentials
print_message "Saving database credentials..."
cat > /root/.joomla_db_credentials << EOF
MySQL Root Password: ${MYSQL_ROOT_PASS}
Joomla Database: ${DB_NAME}
Joomla DB User: ${DB_USER}
Joomla DB Password: ${DB_PASS}
EOF
chmod 600 /root/.joomla_db_credentials

# Download and install Joomla
print_message "Downloading Joomla CMS..."
cd /tmp

# Determine compatible Joomla version based on PHP version
PHP_MAJOR=$(php -r 'echo PHP_MAJOR_VERSION;' 2>/dev/null || echo "8")
PHP_MINOR=$(php -r 'echo PHP_MINOR_VERSION;' 2>/dev/null || echo "1")

if [ "$PHP_MAJOR" -gt 8 ] || ([ "$PHP_MAJOR" -eq 8 ] && [ "$PHP_MINOR" -ge 3 ]); then
    # PHP >= 8.3 — latest Joomla
    print_message "PHP ${PHP_MAJOR}.${PHP_MINOR} detected, downloading latest Joomla..."
    JOOMLA_VERSION=$(curl -s https://api.github.com/repos/joomla/joomla-cms/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
else
    # PHP < 8.3 — use Joomla 5.2.4 (last version supporting PHP 8.1+)
    print_warning "PHP ${PHP_MAJOR}.${PHP_MINOR} detected. Downloading Joomla 5.2.4 (compatible with PHP 8.1+)..."
    JOOMLA_VERSION="5.2.4"
fi

print_message "Installing Joomla version: ${JOOMLA_VERSION}"
wget -q "https://github.com/joomla/joomla-cms/releases/download/${JOOMLA_VERSION}/Joomla_${JOOMLA_VERSION}-Stable-Full_Package.zip" -O joomla.zip

if [ ! -f joomla.zip ] || [ ! -s joomla.zip ]; then
    print_error "Failed to download Joomla. Please check your internet connection."
    exit 1
fi

print_message "Installing Joomla to /var/www/${DOMAIN}..."
mkdir -p /var/www/${DOMAIN}
unzip -q joomla.zip -d /var/www/${DOMAIN}
rm joomla.zip

# Set proper permissions
print_message "Setting file permissions..."
chown -R www-data:www-data /var/www/${DOMAIN}
find /var/www/${DOMAIN} -type d -exec chmod 755 {} \;
find /var/www/${DOMAIN} -type f -exec chmod 644 {} \;

# Create Apache virtual host
print_message "Configuring Apache virtual host..."
cat > /etc/apache2/sites-available/${DOMAIN}.conf <<EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}
    ServerAdmin ${ADMIN_EMAIL}
    DocumentRoot /var/www/${DOMAIN}
    
    <Directory /var/www/${DOMAIN}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}-access.log combined
</VirtualHost>
EOF

# Disable default site and enable new site
a2dissite 000-default.conf 2>/dev/null || true
a2dissite 000-default 2>/dev/null || true
a2ensite ${DOMAIN}.conf

# Reload Apache
systemctl reload apache2

# Obtain SSL certificate with Let's Encrypt
print_message "Obtaining Let's Encrypt SSL certificate..."
print_warning "Make sure your domain ${DOMAIN} points to this server's IP address!"
sleep 3

certbot --apache -d ${DOMAIN} -d www.${DOMAIN} \
    --non-interactive \
    --agree-tos \
    --email ${ADMIN_EMAIL} \
    --redirect

# Set up auto-renewal
print_message "Setting up SSL certificate auto-renewal..."
systemctl enable certbot.timer
systemctl start certbot.timer

# Configure PHP settings for Joomla
print_message "Optimizing PHP configuration..."
PHP_INI=$(php -i 2>/dev/null | grep "Loaded Configuration File" | awk '{print $5}')
if [ -z "$PHP_INI" ] || [ ! -f "$PHP_INI" ]; then
    # Fallback: search for the Apache php.ini
    PHP_INI=$(find /etc/php -path "*/apache2/php.ini" 2>/dev/null | sort -rV | head -1)
fi
if [ -f "$PHP_INI" ]; then
    print_message "Updating PHP config: ${PHP_INI}"
    sed -i 's/upload_max_filesize = .*/upload_max_filesize = 32M/' $PHP_INI
    sed -i 's/post_max_size = .*/post_max_size = 32M/' $PHP_INI
    sed -i 's/memory_limit = .*/memory_limit = 256M/' $PHP_INI
    sed -i 's/max_execution_time = .*/max_execution_time = 300/' $PHP_INI
else
    print_warning "Could not locate php.ini — skipping PHP tuning."
fi

# Restart Apache to apply changes
systemctl restart apache2

# Verify PHP is properly configured for Apache
print_message "Verifying PHP Apache configuration..."
PHP_VERSION=$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo 'unknown')
print_message "PHP Version: ${PHP_VERSION}"

# Display installation summary
print_message "==============================================="
print_message "  Joomla Installation Complete!"
print_message "==============================================="
echo
print_message "Access your Joomla installation at:"
print_message "  https://${DOMAIN}"
echo
print_message "Complete the web-based installation with these credentials:"
print_message "  Database Type: MySQLi"
print_message "  Database Host: localhost"
print_message "  Database Name: ${DB_NAME}"
print_message "  Database User: ${DB_USER}"
print_message "  Database Password: ${DB_PASS}"
echo
print_message "Admin Credentials:"
print_message "  Username: ${ADMIN_USER}"
print_message "  Email: ${ADMIN_EMAIL}"
print_message "  Password: (the password you entered)"
echo
print_message "Database credentials saved to: /root/.joomla_db_credentials"
print_warning "Please save these credentials in a secure location!"
echo
print_message "SSL Certificate: Enabled (Let's Encrypt)"
print_message "Auto-renewal: Enabled"
echo
print_message "==============================================="
