#/bin/bash

rm -Rf /usr/local/src/pcre2.zip /usr/local/src/pcre2* 2> /dev/null
cd /usr/local/src
wget http://static.cdn-cwp.com/files/php/addons/pcre2-10.39.zip -O pcre2.zip
unzip pcre2.zip
cd pcre2-*/
./configure
make && make install
