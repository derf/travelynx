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
 * DBI
 * DBD::Pg
 * Email::Sender
 * Geo::Distance
 * Mojolicious
 * Mojolicious::Plugin::Authentication
 * Travel::Status::DE::IRIS
 * UUID::Tiny

Setup
---

First, you need to set up a PostgreSQL database so that travelynx can store
user accounts and journeys. Version 9.6 or later with UTF-8 locale (e.g.
`en_US.UTF-8`) should work fine.  The following steps describe setup on a
Debian 9 system, though setup on other distribution should be similar.

* Write down a strong random password
* Create a postgres user for travelynx: `sudo -u postgres createuser -P travelynx`
  (enter password when prompted)
* Create the database: `sudo -u postgres createdb -O travelynx travelynx`
* Initialize the database: `TRAVELYNX_DB_HOST=... TRAVELYNX_DB_NAME=... `
  `TRAVELYNX_DB_USER=... TRAVELYNX_DB_PASSWORD=... perl index.pl setup`

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

Usage
---

For the sake of this manual, we will assume your travelynx instance is running
on `travelynx.de`

travelynx journey logging is based on checkin and checkout actions: You check
into a train when boarding it, and check out again when leaving it. Real-time
data is saved on both occasions, providing an accurate overview of both
scheduled and actual journey times.

## Checking in

You can check into a train up to 10 minutes before its scheduled departure and
up to 3 hours after its actual departure (including delays). I recommend
doing so when it arrives at the station or shortly after boarding.

First, you need to select the station you want to check in from.
Navigate to `travelynx.de` or click/tap on the travelynx text in the navigation
bar. You will see a list of the five stations closest to your current location
(as reported by your browser). Select the station you're at or enter its
name or DS100 code manually.

Now, as soon as you select a train, you will be checked in and travelynx
will switch to the journey / checkout view.

## Checking out

You can check out of a train up to 10 minutes before its scheduled arrival and
up to 3 hours after its actual arrival. This ensures that accurate real-time
data for your arrival is available.  I recommend checking out when arriving at
your destination or shortly after having left the train.

Once checked in, `travelynx.de` will show a list of all upcoming stops. Select
one to check out there. You can also check out at a specific station by
navigating to "travelynx.de/s/*station name*" and selecting "Hier auschecken".

If you forgot to check out in time, or are departing the train at a station
which is not part of its documented route (and also not part of its documented
route deviations), or are encountering issues with travelynx' real-time data
fetcher, the checkout action will fail with an error message along the lines
of "no real-time data available" or "train not found".

If you use the checkout link again, travelynx will perform a force checkout: it
will log that you have left the train at the specified station, but omit
arrival time, delay, and other real-time data. At the moment, this data cannot
be specified manually.
