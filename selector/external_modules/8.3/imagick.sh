#!/bin/bash
if [ -e "/opt/alt/php-fpm83/usr/bin/php-config" ];then
yum -y install ImageMagick ImageMagick-devel ImageMagick-perl
cd /usr/local/src
rm -Rf imagick*
git clone https://github.com/Imagick/imagick
cd imagick/
/opt/alt/php-fpm83/usr/bin/phpize
ln -s /usr/local/include/ImageMagick-6 /usr/local/include/ImageMagick
./configure --with-php-config=/opt/alt/php-fpm83/usr/bin/php-config
make clean
make
make install
echo ""

PHPEXTDIR=`/opt/alt/php-fpm83/usr/bin/php-config --extension-dir`

if [ -e "$PHPEXTDIR/imagick.so" ];then 
	echo "Creating config file"
	grep "imagick.so" /opt/alt/php-fpm83/usr/php/php.d/imagick.ini 2> /dev/null 1> /dev/null|| echo "extension=imagick.so" > /opt/alt/php-fpm83/usr/php/php.d/imagick.ini
else
	echo "ERROR: Missing extension file $PHPEXTDIR/imagick.so"
fi
else
echo "Skipping as php build failed"
fi
