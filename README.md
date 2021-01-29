travelynx - Railway Travel Logger
---

[travelynx](https://finalrewind.org/projects/travelynx/) allows checking into
and out of individual trains, thus providing a log of your railway journeys
annotated with real-time delays and service messages. At the moment, it only
supports german railways and trains which are exposed by the Deutsche Bahn
[IRIS Interface](https://finalrewind.org/projects/Travel-Status-DE-IRIS/).

Dependencies
---

 * perl >= 5.20
 * carton or cpanminus
 * build-essential
 * libpq-dev
 * git

Perl Dependencies
---

travelynx depends on a set of Perl modules which are documented in `cpanfile`.
After installing the dependencies mentioned above, you can use carton or
cpanminus to install Perl depenencies locally.

In the project root directory (where `cpanfile` resides), run either

```
carton install
```

or

```
cpanm --installdeps .
```

and set `PERL5LIB=.../local/lib/perl5` before executing any travelynx
commands (see configs in the examples directory) or wrap them with `carton
exec`, e.g. `carton exec hypnotoad index.pl`

Setup
---

First, you need to set up a PostgreSQL database so that travelynx can store
user accounts and journeys. It must be at least version 9.4 and must use a
UTF-8 locale. The following steps describe setup on a Debian 9 system;
setup on other distributions should be similar.

* Write down a strong random password
* Create a postgres user for travelynx: `sudo -u postgres createuser -P travelynx`
  (enter password when prompted)
* Create the database: `sudo -u postgres createdb -O travelynx travelynx`
* Copy `examples/travelynx.conf` to the application root directory
  (the one in which `index.pl` resides) and edit it. Make sure to configure
  db, cache, mail, and secrets.
* Initialize the database: `carton exec perl index.pl database migrate`
  or `PERL5LIB=local/lib/perl5 perl index.pl database migrate`

Your server also needs to be able to send mail. Set up your MTA of choice and
make sure that the sendmail binary can be used for outgoing mails. Mail
reception on the server is not required.

Finally, configure the web service:

* Set up a travelynx service using the service supervisor of your choice
  (see `examples/travelynx.service` for a systemd unit file)
* Configure your web server to reverse-provy requests to the travelynx
  instance. See `examples/nginx-site` for an nginx config.
* Install a `timeout 5m perl index.pl work -m production` cronjob. It is used
  to update realtime data and perform automatic checkout and should run
  every three minutes or so, see `examples/cron`.

You can now start the travelynx service, navigate to the website and register
your first account. There is no admin account, all management is performed
via cron or (in non-standard cases) on the command line.

Please open an issue on <https://github.com/derf/travelynx/issues> or send a
mail to derf+travelynx@finalrewind.org if there is anything missing or
ambiguous in this setup manual.

Updating
---

It is recommended to run travelynx directly from the git repository. When
updating, the workflow depends on whether schema updates need to be applied
or not.

```
git pull
chmod -R a+rX . # only needed if travelynx is running under a different user
if perl index.pl database has-current-schema; then
    systemctl reload travelynx
else
    systemctl stop travelynx
    perl index.pl database migrate
    systemctl start travelynx
fi
```

Note that this is subject to change -- the application may perform schema
updates automatically in the future. If you used carton for installation,
use `carton exec perl ...` in the snippet above; if you used cpanm, export
`PERL5LIB=.../local/lib/perl5`.

Usage
---

For the sake of this manual, we will assume your travelynx instance is running
on `travelynx.de`

travelynx journey logging is based on checkin and checkout actions: You check
into a train when boarding it, select a destination, and are automatically
checked out when you arrive. Real-time data is saved on both occasions and
continuously updated while in transit, providing an accurate overview of both
scheduled and actual journey times.

## Checking in

You can check into a train up to 30 minutes before its scheduled departure and
up to two hours after its actual departure (including delays).

First, you need to select the station you want to check in from.
Navigate to `travelynx.de` or click/tap on the travelynx text in the navigation
bar. You will see a list of the five stations closest to your current location
(as reported by your browser). Select the station you're at or enter its
name or DS100 code manually.

As soon as you select a train, you will be checked in and travelynx will switch
to the journey / checkout view. If you already know where you're headed, you
should click/tap on the destination station in the station list now. You can
change the destination by selecting a new one anytime.

## Checking out

You are automatically checked out a few minutes after arrival at your
destination. If the train has already arrived when you select a destination and
its arrival was less than two hours ago, you are checked out immediately.  If
it's more than two hours, you need to perform a manual checkout (without
arrival data) using the link at the bottom of the checkin menu's station list.

Testing
---

The test scripts assume that travelynx.conf contains a valid database
connection. They will create a test-specific schema, perform all operations in
it, and then drop the schema. As such, the database specified in the config is
not affected.

Nevertheless, bugs may happen. Do NOT run tests on your production database.
Please use a separate development database instead.

Run the tests by executing `prove`. Use `prove -v` for debug output and
`DBI_TRACE=SQL prove -v` to monitor SQL queries.

Licensing
---

The copyright of individual files is documented in the file's header or in
.reuse/dep5. The referenced licenses are stored in the LICENSES directory.

The program code of travelynx is licensed under the terms of the GNU AGPL v3.
HTML Templates and SASS/CSS layout are licensed under the terms of the MIT
License. This means that you are free to host your own travelynx instance,
both for personal/internal and public use, under the following conditions.

* You are free to change HTML/SASS/CSS templates as you see fit (though you
  must not remove the copyright headers).
* If you make changes to the program code, that is, a file below lib/ or a
  travelynx javascript file below public/static/js/, you must make those
  changes available to the public.

The easiest way of making changes available is by maintaining a public fork of
the Git repository. A tarball is also acceptable.
