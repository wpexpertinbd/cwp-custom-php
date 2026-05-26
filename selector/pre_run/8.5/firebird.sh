#/bin/bash

yum --enablerepo=epel -y install firebird firebird-devel
ln -s /usr/lib64/libncurses.so.6.1 /usr/lib64/libncurses.so.5
cd /usr/local
rm -rf /opt/firebird
wget http://static.cdn-cwp.com/files/php/selector/el9/dependencies/firebird.tar.gz
tar -xvzf firebird.tar.gz
rm -rf firebird.tar.gz