#!/bin/sh
#
# Copyright (C) Markus Witt
# Copyright (C) Birte Kristina Friesel
#
# SPDX-License-Identifier: CC0-1.0

set -e

if ! [ -r travelynx.conf ]; then
	echo "Configuration file (travelynx.conf) is missing. Did you set up the '/local' mountpoint?"
	exit 1
fi

. local/email-transport.sh

if [ "$1" = worker ]; then
	exec perl index.pl worker
fi

perl index.pl database migrate
exec hypnotoad -f index.pl
