cd /usr/local/src
rm -rf master* libavif-* build-dir
wget static.cdn-cwp.com/files/php/addons/libavif-0.11.1.zip
unzip libavif-0.11.1
mkdir build-dir
cd build-dir
cmake3 ../libavif-0.11.1
make
make install