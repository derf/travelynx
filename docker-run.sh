#!/bin/bash
#
# Copyright (C) Markus Witt
#
# SPDX-License-Identifier: CC0-1.0
set -eu

WAIT_DB_HOST=${TRAVELYNX_DB_HOST}
WAIT_DB_PORT=5432

check_config() {
	if [ ! -f travelynx.conf ]
	then
		echo "The configuration file is missing"
		exit 1
	fi	
}

wait_for_db() {
	set +e
	for i in $(seq 1 ${WAIT_DB_TIMEOUT:-5})
	do
		(echo >/dev/tcp/${WAIT_DB_HOST}/${WAIT_DB_PORT}) &>/dev/null
		if [ $? -eq 0 ]; then
		    break
		else
			echo "Can't reach DB @ ${WAIT_DB_HOST}:${WAIT_DB_PORT}"
		fi
		sleep 1
	done
	set -e
}

run_app() {
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
}

run_cron() {
	exec perl index.pl worker
}

check_config
wait_for_db

if [ "${CRON:-0}" -ne "0" ]
then
	run_cron
fi

run_app
