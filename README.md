travelynx - Railway Travel Logger
---

[travelynx](https://finalrewind.org/projects/travelynx/) allows checking into
and out of individual trains, thus providing a log of your railway journeys
annotated with real-time delays and service messages. At the moment, it only
supports german railways and trains which are exposed by the Deutsche Bahn
[IRIS Interface](https://finalrewind.org/projects/Travel-Status-DE-IRIS/).

Dependencies
---

 * perl >= 5.10
 * Cache::File (part of the Cache module)
 * Crypt::Eksblowfish
 * DateTime
 * DateTime::Format::Strptime
 * Email::Sender
 * Geo::Distance
 * Mojolicious
 * Mojolicious::Plugin::Authentication
 * Mojo::Pg
 * Travel::Status::DE::IRIS
 * UUID::Tiny
 * JSON

You can use carton or cpanminus to install dependencies locally. Run either

```
carton install
```

or

```
cpanm --installdeps .
```

and then set `PERL5LIB` before executing any travelynx commands. You may
also be able to use `carton exec` to do this for you, though this is untested.

Recommended
---

 * Geo::Distance::XS (speeds up statistics)
 * JSON::XS (speeds up API and statistics)

Dependencies On Docker
---

 * cpanminus
 * build-essential
 * libpq-dev
 * git
 * ssmtp

Setup
---

First, you need to set up a PostgreSQL database so that travelynx can store
user accounts and journeys. It must be at least version 9.4 and should use a
UTF-8 locale. The following steps describe setup on a Debian 9 system, though
setup on other distribution should be similar.

* Write down a strong random password
* Create a postgres user for travelynx: `sudo -u postgres createuser -P travelynx`
  (enter password when prompted)
* Create the database: `sudo -u postgres createdb -O travelynx travelynx`
* Copy `examples/travelynx.conf` to the application root directory
  (the one in which `index.pl` resides) and configure it
* Initialize the database: `perl index.pl database migrate`

Your server also needs to be able to send mail. Set up your MTA of choice and
make sure that the sendmail binary can be used for outgoing mails. Mail
reception on the server is not required.

Finally, configure the web service:

* Set up a travelynx service using the service supervisor of your choice
  (see `examples/travelynx.service` for a systemd unit file)
* Configure your web server to reverse-provy requests to the travelynx
  instance. See `examples/nginx-site` for an nginx config.

You can now start the travelynx service, navigate to the website and register
your first account.

Please open an issue on <https://github.com/derf/travelynx/issues> or send a
mail to derf+travelynx@finalrewind.org if there is anything missing or
ambiguous in this setup manual.

Updating
---

It is recommended to run travelynx directly from the git repository. When
updating, the workflow depends on whether schema updates need to applied
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
updates automatically in the future.

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
to the journey / checkout view. If you already now where you're headed, you
should click/tap on the destination station in the station list now. You can
change the destination by selecting a new one any time.

## Checking out

You are automatically checked out a few minutes after arrival at your
destination. If the train has already arrived when you select a destination and
its arrival was less than two hours ago, you are checked out immediately.  If
it's more than two hours, it will not be included in the scheduled and
real-time data fetched by travelynx. In this case, you have to check out
without arrival data using the link at the bottom of the checkin menu's station
list.

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
