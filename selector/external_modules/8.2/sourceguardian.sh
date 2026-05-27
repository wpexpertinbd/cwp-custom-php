#!/bin/bash

cd /usr/local
wget -U 'Mozilla/5.0 (X11; Linux x86_64; rv:30.0) Gecko/20100101 Firefox/30.0' https://www.sourceguardian.com/loaders/download/loaders.linux-x86_64.zip -O sourceguardian64.zip
unzip -o sourceguardian64.zip -d /usr/local/sourceguardian
rm -rf /opt/alt/php-fpm82/usr/php/php.d/sourceguardian.ini
touch /opt/alt/php-fpm82/usr/php/php.d/sourceguardian.ini
if [ -e "/usr/local/sourceguardian/ixed.8.2.lin" ];then
	grep "ixed.8.2.lin" /opt/alt/php-fpm82/usr/php/php.d/sourceguardian.ini 2> /dev/null 1> /dev/null|| echo "zend_extension=/usr/local/sourceguardian/ixed.8.2.lin" >> /opt/alt/php-fpm82/usr/php/php.d/sourceguardian.ini
fi
