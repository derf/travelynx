#!/bin/sh
#
# Updates a travelynx instance deployed via git. Performs database migrations
# as necessary.

git pull
git submodule update --init

if [ "$1" = "with-deps" ]; then
	mkdir local.new
	cd local.new
	cp ../cpanfile* .
	carton install
	cd ..
	sudo systemctl stop travelynx
	touch maintenance
	mv local local.old
	mv local.new/local .
	perl index.pl database migrate
	rm -f maintenance
	sudo systemctl start travelynx
elif perl index.pl database has-current-schema; then
	sudo systemctl reload travelynx
else
	sudo systemctl stop travelynx
	perl index.pl database migrate
	sudo systemctl start travelynx
fi
