#!/bin/bash
exec > /var/log/user-data.log 2>&1
set -x

# Ensure UTF-8 for emojis
export LANG=C.UTF-8

# Wait for network
for i in {1..30}; do ping -c1 8.8.8.8 && break; sleep 2; done

# Update system & install dependencies
dnf clean all && dnf makecache
dnf -y update
dnf -y install httpd php php-mysqli unzip php-cli php-json php-mbstring awscli mod_ssl 

systemctl enable httpd
systemctl start httpd

# Create web root
mkdir -p /var/www/html
cd /var/www/html
chown -R apache:apache /var/www/html
chmod -R 755 /var/www/html

# Decode and unzip index.zip (provided by Terraform)
echo "${INDEX_ZIP}" | base64 -d > index.zip
unzip -o index.zip
rm index.zip

# Inject BACKEND_URL into PHP and JS placeholders
sed -i "s|%%BACKEND_URL%%|${BACKEND_URL}|g" /var/www/html/index.php

# Generate a self-signed certificate if none exists
if [ ! -f /var/www/html/cert.pem ]; then
  openssl req -x509 -nodes -days 365 \
    -subj "/C=US/ST=Test/L=Test/O=Test/CN=localhost" \
    -newkey rsa:2048 \
    -keyout /var/www/html/privkey.pem \
    -out /var/www/html/cert.pem
  cp /var/www/html/cert.pem /var/www/html/chain.pem
fi

# Backup default ssl.conf
if [ -f /etc/httpd/conf.d/ssl.conf ]; then
  mv /etc/httpd/conf.d/ssl.conf /etc/httpd/conf.d/ssl.conf.bak
fi

# Create custom VirtualHost
cat <<EOF > /etc/httpd/conf.d/ssl.conf
Listen 443 https
SSLPassPhraseDialog  builtin
SSLSessionCache         shmcb:/run/httpd/sslcache(512000)
SSLSessionCacheTimeout  300

<VirtualHost *:443>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile /var/www/html/cert.pem
    SSLCertificateKeyFile /var/www/html/privkey.pem

    <Directory /var/www/html>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog /var/log/httpd/ssl-error.log
    CustomLog /var/log/httpd/ssl-access.log combined
</VirtualHost>
EOF

# Fix permissions again
chown -R apache:apache /var/www/html
chmod -R 755 /var/www/html

# Restart Apache to apply changes
systemctl restart httpd
