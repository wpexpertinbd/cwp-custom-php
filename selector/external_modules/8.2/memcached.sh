#!/bin/bash
if [ -e "/opt/alt/php-fpm82/usr/bin/php-config" ];then
cd /usr/local/src
wget https://launchpad.net/libmemcached/1.0/1.0.18/+download/libmemcached-1.0.18.tar.gz
tar -zxvf libmemcached-1.0.18.tar.gz
cd libmemcached-1.0.18
./configure
make && make install
yum -y install memcached
systemctl enable memcached
systemctl restart memcached
cd /usr/local/src
rm -rf memcached*
curl https://pecl.php.net/get/memcached -o memcached.tgz
tar -xf memcached.tgz
cd memcached-*/
/opt/alt/php-fpm82/usr/bin/phpize
./configure --with-php-config=/opt/alt/php-fpm82/usr/bin/php-config
make
make install

PHPEXTDIR=`/opt/alt/php-fpm82/usr/bin/php-config --extension-dir`

if [ -e "$PHPEXTDIR/memcached.so" ];then 
	echo "Creating config file"
	grep "memcached.so" /opt/alt/php-fpm82/usr/php/php.d/memcached.ini 2> /dev/null 1> /dev/null|| echo "extension=memcached.so" > /opt/alt/php-fpm82/usr/php/php.d/memcached.ini
else
	echo "ERROR: Missing extension file $PHPEXTDIR/memcached.so"
fi
else
echo "Skipping as php build failed"
fi
