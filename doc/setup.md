# Hosting your own travelynx

This document describes how to host your own travelynx instance.

## Dependencies

 * perl ≥ 5.20
 * carton
 * build-essential
 * libpq-dev
 * git

## Installation

travelynx depends on a set of Perl modules which are documented in `cpanfile`.
After installing the dependencies mentioned above, you can use carton to
install Perl depenencies locally. You may alsobe able to use cpanminus;
however this method is untested.

In the project root directory (where `cpanfile` resides), run

```
carton install --deployment
```

and set `PERL5LIB=.../local/lib/perl5` before executing any travelynx
commands (see configs in the examples directory) or wrap them with `carton
exec`, e.g. `carton exec hypnotoad index.pl`

## Setup

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

Note that Deutsche Bahn have put parts of their API behind an IP reputation
filter. In general, checkins with the bahn.de backend will only be possible if
travelynx is accessing it from a residential (non-server) IP range.  See the
dbris bahn.de proxy / proxies setting in `example/travelynx.conf` for
workarounds.

## Updating

It is recommended to run travelynx directly from the git repository. When
updating, the workflow depends on whether schema updates need to be applied
or not.

```
git pull
carton install --deployment # if you are using carton: update dependencies
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
use `carton exec perl ...` in the snippet above; otherwise, export
`PERL5LIB=.../local/lib/perl5`.

## Setup with Docker
---

Note that travelynx Docker support is experimental and, in its current form,
far from best practices. Pull requests are appreciated.

First, you need to set up a PostgreSQL database so that travelynx can store
user accounts and journeys. It must be at least version 9.4 and must use a
UTF-8 locale. See above (or `examples/docker/postgres-init.sh`) for database
initialization. You do not need to perform the `database migrate` step.

Next, you need to prepare three files that will be mounted into the travelynx
container: travelynx configuration, e-mail configuration, and imprint and
privacy policy. For the sake of this readme, we assume that you are using the
`local/` directory to store these

* `mkdir local`
* copy examples/travelynx.conf to local/travelynx.conf and configure it.
* copy examples/docker/email-transport.sh to local/email-transport.sh and configure it.
  The travelynx container does not contain a mail server, so it needs a
  separate SMTP server to send mail. It does not receive mail.
* create local/imprint.html.ep and enter imprint as well as privacy policy data.
* create local/terms-of-service.html.ep and enter your terms of service.
* Configure your web server to reverse-provy requests to the travelynx
  instance. See `examples/nginx-site` for an nginx config.

travelynx consists of two runtimes: the web application and a background
worker. Your service supervisor (or docker compose / docker stack / kubernetes
setup) should orchestrate them somewhere along these lines.

* `docker pull derfnull/travelynx:latest`
* Start web application: `docker run -p 8093:8093 -v ${PWD}/local:/local:ro travelynx:latest`
* Wait until localhost:8093 responds to requests
* Start worker: `docker run -v ${PWD}/local:/local:ro travelynx:latest worker`

To install an update: stop worker and web application, update the travelynx
image, and start them again. Database migrations will be performed
automatically. Note that downgrades are not supported.
