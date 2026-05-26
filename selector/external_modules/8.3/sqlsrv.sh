#!/bin/bash

cd /usr/local/src
yum install unixODBC unixODBC-devel -y
rm -rf sqlsrv*
wget http://static.cdn-cwp.com/files/php/pecl/sqlsrv-5.10.0beta1.tgz
tar -xf sqlsrv-*
cd sqlsrv-*/
/opt/alt/php-fpm83/usr/bin/phpize
./configure --with-php-config=/opt/alt/php-fpm83/usr/bin/php-config
make
make install

PHPEXTDIR=`/opt/alt/php-fpm83/usr/bin/php-config --extension-dir`

if [ -e "$PHPEXTDIR/sqlsrv.so" ];then 
	echo "Creating config file"
	grep "sqlsrv.so" /opt/alt/php-fpm83/usr/php/php.d/sqlsrv.ini 2> /dev/null 1> /dev/null|| echo "extension=sqlsrv.so" > /opt/alt/php-fpm83/usr/php/php.d/sqlsrv.ini
else
	echo "ERROR: Missing extension file $PHPEXTDIR/sqlsrv.so"
fi

rm -rf pdo_sqlsrv*
wget http://static.cdn-cwp.com/files/php/pecl/pdo_sqlsrv-5.10.0beta1.tgz
tar -xf pdo_sqlsrv-*
cd pdo_sqlsrv-*/
/opt/alt/php-fpm83/usr/bin/phpize
./configure --with-php-config=/opt/alt/php-fpm83/usr/bin/php-config
make
make install

if [ -e "$PHPEXTDIR/pdo_sqlsrv.so" ];then 
	echo "Creating config file"
	grep "pdo_sqlsrv.so" /opt/alt/php-fpm83/usr/php/php.d/pdo_sqlsrv.ini 2> /dev/null 1> /dev/null|| echo "extension=pdo_sqlsrv.so" > /opt/alt/php-fpm83/usr/php/php.d/pdo_sqlsrv.ini
else
	echo "ERROR: Missing extension file $PHPEXTDIR/pdo_sqlsrv.so"
fi
