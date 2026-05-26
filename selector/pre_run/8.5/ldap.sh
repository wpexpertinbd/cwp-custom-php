#/bin/bash

yum -y install openldap compat-openldap openldap-clients openldap-servers openldap-servers-sql openldap-devel openldap.i686 openldap-devel.i686

ln -s /usr/lib64/libldap.so /usr/lib/libldap.so
ln -s /usr/lib64/libldap_r.so /usr/lib/libldap_r.s