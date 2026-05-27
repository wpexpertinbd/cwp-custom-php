#!/bin/bash
# pre_run/8.3/php83.sh
# Build PCRE2 10.39 to /usr/local/lib so PHP 8.3's configure can pick it up.
# CPPFLAGS/LDFLAGS/PKG_CONFIG_PATH exports force libs to resolve from /usr
# during pcre2's own build — without them, pcre2 linker may pick stale
# /usr/local/lib remnants and produce an ABI-mismatched binary that PHP
# later loads with "unrecognised compile-time option bit(s)" warnings on
# every preg_* call (real-world break: WP critical error on s1, 2026-05-27).
# Matches the working pattern in pre_run/8.4/php84.sh.

export CPPFLAGS="-I/usr/include"
export LDFLAGS="-L/usr/lib64"
export PKG_CONFIG_PATH="/usr/lib64/pkgconfig"

rm -Rf /usr/local/src/pcre2.zip /usr/local/src/pcre2* 2> /dev/null
cd /usr/local/src
wget http://static.cdn-cwp.com/files/php/addons/pcre2-10.39.zip -O pcre2.zip
unzip pcre2.zip
cd pcre2-*/
./configure
make && make install
