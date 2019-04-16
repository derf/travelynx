#!/bin/sh
set -eu

if [ ! -f travelynx.conf ]
then
	echo "The configuration file is missing"
	exit 1
fi

if [ \
	"${TRAVELYNX_MAIL_DISABLE:-0}" -eq 0 \
	-a "${TRAVELYNX_MAIL_HOST:-unset}" != "unset" \
]
then
	export EMAIL_SENDER_TRANSPORT=SMTP
	export EMAIL_SENDER_TRANSPORT_HOST=${TRAVELYNX_MAIL_HOST}
	export EMAIL_SENDER_TRANSPORT_PORT=${TRAVELYNX_MAIL_PORT:-25}
fi

perl index.pl database migrate

exec /usr/local/bin/hypnotoad -f index.pl
