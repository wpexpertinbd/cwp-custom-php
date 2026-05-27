#!/bin/bash

IONCUBEVER="8.2"
IONCUBESHORT="82"

rm -rf /opt/alt/php-fpm$IONCUBESHORT/usr/php/php.d/ioncube.ini
touch /opt/alt/php-fpm$IONCUBESHORT/usr/php/php.d/ioncube.ini

if [ -e "/usr/local/ioncube/ioncube_loader_lin_$IONCUBEVER.so" ];then
        grep "ioncube_loader_lin_$IONCUBEVER.so" /opt/alt/php-fpm$IONCUBESHORT/usr/php/php.d/ioncube.ini 2> /dev/null 1> /dev/null|| echo "zend_extension=/usr/local/ioncube/ioncube_loader_lin_$IONCUBEVER.so" > /opt/alt/php-fpm$IONCUBESHORT/usr/php/php.d/ioncube.ini
else
        sh /scripts/update_ioncube
        if [ -e "/usr/local/ioncube/ioncube_loader_lin_$IONCUBEVER.so" ];then
                grep "ioncube_loader_lin_$IONCUBEVER.so" /opt/alt/php-fpm$IONCUBESHORT/usr/php/php.d/ioncube.ini 2> /dev/null 1> /dev/null|| echo "zend_extension=/usr/local/ioncube/ioncube_loader_lin_$IONCUBEVER.so" > /opt/alt/php-fpm$IONCUBESHORT/usr/php/php.d/ioncube.ini
        fi
fi

