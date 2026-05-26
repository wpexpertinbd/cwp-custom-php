#!/bin/bash
if [ -e "/opt/alt/php-fpm83/usr/bin/php-config" ];then
PHPEXTDIR=`/opt/alt/php-fpm83/usr/bin/php-config --extension-dir`
if [ -e "$PHPEXTDIR/opcache.so" ];then 
echo	"Creating config file"
	grep "$PHPEXTDIR/opcache.so" /opt/alt/php-fpm83/usr/php/php.d/opcache.ini 2> /dev/null 1> /dev/null|| echo "zend_extension=$PHPEXTDIR/opcache.so" > /opt/alt/php-fpm83/usr/php/php.d/opcache.ini
	grep "^opcache.enable" /opt/alt/php-fpm83/usr/php/php.d/opcache.ini 2> /dev/null 1> /dev/null|| echo "opcache.enable=1" >> /opt/alt/php-fpm83/usr/php/php.d/opcache.ini
	grep "^opcache.memory_consumption" /opt/alt/php-fpm83/usr/php/php.d/opcache.ini 2> /dev/null 1> /dev/null|| echo "opcache.memory_consumption=128" >> /opt/alt/php-fpm83/usr/php/php.d/opcache.ini
	grep "^opcache.interned_strings_buffer" /opt/alt/php-fpm83/usr/php/php.d/opcache.ini 2> /dev/null 1> /dev/null|| echo "opcache.interned_strings_buffer=8" >> /opt/alt/php-fpm83/usr/php/php.d/opcache.ini
	grep "^opcache.max_accelerated_files" /opt/alt/php-fpm83/usr/php/php.d/opcache.ini 2> /dev/null 1> /dev/null|| echo "opcache.max_accelerated_files=5000" >> /opt/alt/php-fpm83/usr/php/php.d/opcache.ini
	grep "^opcache.revalidate_freq" /opt/alt/php-fpm83/usr/php/php.d/opcache.ini 2> /dev/null 1> /dev/null|| echo "opcache.revalidate_freq=60" >> /opt/alt/php-fpm83/usr/php/php.d/opcache.ini
	grep "^opcache.fast_shutdown" /opt/alt/php-fpm83/usr/php/php.d/opcache.ini 2> /dev/null 1> /dev/null|| echo "opcache.fast_shutdown=1" >> /opt/alt/php-fpm83/usr/php/php.d/opcache.ini
	grep "^opcache.enable_cli" /opt/alt/php-fpm83/usr/php/php.d/opcache.ini 2> /dev/null 1> /dev/null|| echo "opcache.enable_cli=1" >> /opt/alt/php-fpm83/usr/php/php.d/opcache.ini
else
	echo "ERROR: Missing extension file $PHPEXTDIR/opcache.so"
fi
else
echo "Skipping as php build failed"
fi
