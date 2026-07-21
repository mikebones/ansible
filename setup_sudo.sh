#!/bin/sh
# setup_sudo.sh — grant passwordless sudo to `administrator` on a fresh node,
# matching the existing cluster nodes (so ansible's become works without a
# password prompt). Run remotely via:
#   SSHPASS='<login pw>' sshpass -e ssh administrator@<host> bash -s < setup_sudo.sh
# Uses the login password once (fed to sudo -S) to write the sudoers drop-in.
echo '0830Bones!' | sudo -S sh -c 'umask 022; printf "administrator ALL=(ALL) NOPASSWD:ALL\n" > /etc/sudoers.d/administrator && chmod 440 /etc/sudoers.d/administrator' 2>/dev/null
echo "nopasswd-check: $(sudo -n whoami 2>&1)"