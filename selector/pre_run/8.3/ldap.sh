#!/bin/bash
# Best-effort LDAP dev headers + libdir symlinks.
# Idempotent — re-runs safely (ln -sf, dnf -y).

dnf -y install openldap openldap-clients openldap-devel || true
# These two often fail on EL8 (compat-openldap/openldap-servers-sql moved/removed)
dnf -y install compat-openldap 2>/dev/null || true
dnf -y install openldap-servers-sql 2>/dev/null || true
dnf -y install openldap-servers 2>/dev/null || true

# Re-runnable symlinks (the original script used `ln -s` which fails on existing files,
# and the second link had a typo: libldap_r.s instead of libldap_r.so)
if [ -e /usr/lib64/libldap.so ]; then
    ln -sf /usr/lib64/libldap.so /usr/lib/libldap.so || true
fi
if [ -e /usr/lib64/libldap_r.so ]; then
    ln -sf /usr/lib64/libldap_r.so /usr/lib/libldap_r.so || true
fi

exit 0
