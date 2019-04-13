#!/bin/sh
set -eu

if [ ! -f travelynx.conf ]
then
	echo "The configuration file is missing"
	exit 1
fi

perl index.pl database migrate

exec /usr/local/bin/hypnotoad -f index.pl