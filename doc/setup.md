# Hosting your own travelynx

This document describes how to host your own travelynx instance.

## Assumptions

Parts of this documentation make the following assumptions

* The travelynx web service and associated commands will be run by the UNIX user `travelyx`, which you have already set up.
* You have a git clone of https://git.finalrewind.org/derf/travelynx.git in a suitable directory, e.g. `/srv/www/travelynx`.
* The git clone is readable by the `travelynx` user (this applies to both `.git` and all checked-out files).

Unless noted otherwise, all of the following commands are run as the `travelynx` user.

## Dependencies

On Debian 13 (trixie), the following packages are required:

 * perl ≥ 5.40
 * carton (Perl package manager)
 * build-essential (C/C++ compiler and build utilities)
 * git
 * libdb5.3-dev
 * libpq-dev
 * libssl-dev
 * libxml2-dev
 * zlib1g-dev

## Installation

travelynx depends on a set of Perl modules which are documented in `cpanfile`.
After installing the dependencies mentioned above, you can use **carton** to install Perl depenencies locally.
You may alsobe able to use cpanminus; however, this method is untested.

In the project root directory (where `cpanfile` resides, e.g., `/srv/www/travelynx`), run

```
carton install --deployment
```

Afterwards, either set `PERL5LIB=/srv/www/travelynx/local/lib/perl5` (or similar) before executing any travelynx commands (see configs in the examples directory), or wrap them with `carton exec`, e.g. `carton exec hypnotoad index.pl`

## Setup

### Database

First, you need to set up a PostgreSQL database so that travelynx can store user accounts and journeys.
It must be at least version 9.4 and must use a UTF-8 locale.
The following steps describe setup on a Debian 9 system; setup on other distributions should be similar.

* Write down a strong random password
* Create a postgres user for travelynx: `sudo -u postgres createuser -P travelynx` (enter password when prompted)
* Create the database: `sudo -u postgres createdb -O travelynx travelynx`
* Copy `examples/travelynx.conf` to the git repository's root directory (the one in which `index.pl` resides, e.g., `/srv/www/travelynx`), and edit it.
* Make sure to configure db, cache, mail, and secrets.
* Initialize the database: `carton exec perl index.pl database migrate`

### Mail

In case you plan to operate a travelynx instance that allows anyone to register an account, your server also needs to be able to send mail.
Set up your MTA of choice and make sure that the sendmail binary can be used for outgoing mails.
Mail reception on the server is not required.

### Web Service

Finally, configure the web service:

* Set up a travelynx service using the service supervisor of your choice
  (see `examples/travelynx.service` for a systemd unit file)
* Ensure that `public/tmp` is writable by the `travelynx` user
* create `templates/imprint.html.ep` and enter imprint as well as privacy policy data.
* create `templates/terms-of-service.html.ep` and enter your terms of service.
* Configure your web server to reverse-provy requests to the travelynx web service.
  See `examples/nginx-site` for an appropriate nginx config snippet.
* Install a `timeout 5m carton exec perl index.pl work -m production` cronjob.
  It is used to update realtime data and perform automatic checkout and should run every three minutes or so, see `examples/cron`.

You can now start the travelynx service, navigate to the website and register your first account.
There is no admin account; all management is performed via cron or (in non-standard cases) on the command line.

Please open an issue on <https://github.com/derf/travelynx/issues> or send a mail to derf+travelynx@finalrewind.org if there is anything missing or ambiguous in this setup manual.

Note that Deutsche Bahn have put parts of their API behind an IP reputation filter.
In general, checkins with the bahn.de backend will only be possible if travelynx is accessing it from a residential (non-server) IP range.
See the dbris bahn.de proxy / proxies setting in `example/travelynx.conf` for workarounds.

## Updating

It is recommended to run travelynx directly from the git repository.  This way,
**examples/update.sh** will automatically perform a git pull and apply any
required database migrations. For releases that bump dependency versions or
introduce new dependencies, run **examples/update.sh with-deps**.

If you are not using carton, or have some other peculiarities in your setup,
you may need to adjust the script.

## Setup with Docker (EXPERIMENTAL)
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
