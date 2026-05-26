#!/bin/bash
set -e

# IMAP dependencies for AlmaLinux 8 / 9
dnf -y install \
  uw-imap-devel \
  krb5-devel \
  openssl-devel
