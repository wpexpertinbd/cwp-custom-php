#!/bin/bash

cd /usr/local/src
wget http://ftp.indexdata.dk/pub/yaz/yaz-5.28.0.tar.gz -O yaz.tar.gz
tar -zxvf yaz.tar.gz
cd yaz-*/
./configure
make
make install
cd /usr/local/src
curl https://pecl.php.net/get/yaz -o yaz.tgz
tar -zxvf yaz.tgz
cd yaz-*/
/opt/alt/php-fpm82/usr/bin/phpize
./configure --with-php-config=/opt/alt/php-fpm82/usr/bin/php-config
make
make install
rm -rf yaz*

PHPEXTDIR=`/opt/alt/php-fpm82/usr/bin/php-config --extension-dir`

if [ -e "$PHPEXTDIR/yaz.so" ];then 
	echo "Creating config file"
	grep "yaz.so" /opt/alt/php-fpm82/usr/php/php.d/yaz.ini 2> /dev/null 1> /dev/null|| echo "extension=yaz.so" > /opt/alt/php-fpm82/usr/php/php.d/yaz.ini
else
	echo "ERROR: Missing extension file $PHPEXTDIR/yaz.so"
fi



