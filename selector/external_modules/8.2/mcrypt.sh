#!/bin/bash

cd /usr/local/src
rm -rf mcrypt*
wget http://static.cdn-cwp.com/files/php/pecl/mcrypt-1.0.4.tgz
tar -xf mcrypt-*
cd mcrypt-*/
phpize
./configure --with-php-config=/opt/alt/php-fpm82/usr/bin/php-config
make
make install
touch /opt/alt/php-fpm82/usr/php/php.d/mcrypt.ini
grep "mcrypt.so" /opt/alt/php-fpm82/usr/php/php.d/mcrypt.ini 2> /dev/null 1> /dev/null|| echo "extension=mcrypt.so" >> /opt/alt/php-fpm82/usr/php/php.d/mcrypt.ini
