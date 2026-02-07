travelynx - Railway Travel Logger
---

[travelynx](https://finalrewind.org/projects/travelynx/) allows checking into
individual public transit vehicles (e.g. buses, ferries, trams, trains) across
most of Germany, Switzerland, Austria, Luxembourg, Ireland, Denmark, and parts
of the USA. Thus, it provides a log of your railway journeys annotated with
real-time delays and service messages, if available. It supports German
long-distance, regional and local transit exposed by the Deutsche Bahn [bahn.de
interface](https://finalrewind.org/projects/Travel-Status-DE-DBRIS/), a variety
of [EFA](https://finalrewind.org/projects/Travel-Status-DE-VRR/) and
[HAFAS](https://finalrewind.org/projects/Travel-Status-DE-HAFAS/) interfaces,
andt [MOTIS](https://finalrewind.org/projects/Travel-Status-MOTIS/) APIs
including the [transitous](https://transitous.org/) aggregator.

You can use the public instance on [travelynx.de](https://travelynx.de) or
host your own. Further reading:

* [Contributing](doc/contributing.md) to travelynx development
* [Setup](doc/setup.md) for hosting your own instance
* [Usage](doc/usage.md) primer (what is this whole “checking in” about?)

## Testing

The test scripts assume that travelynx.conf contains a valid database
connection. They will create a test-specific schema, perform all operations in
it, and then drop the schema. As such, the database specified in the config is
not affected.

Nevertheless, bugs may happen. Do NOT run tests on your production database.
Please use a separate development database instead.

Run the tests by executing `prove`. Use `prove -v` for debug output and
`DBI_TRACE=SQL prove -v` to monitor SQL queries.

## Licensing

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
the Git repository. A tarball is also acceptable. Please change the `source`
ref in travelynx.conf if you are using a fork with custom changes.

## References

Mirrors of the travelynx repository are maintained at the following locations:

* [Codeberg](https://codeberg.org/derf/travelynx)
* [Finalrewind](https://git.finalrewind.org/derf/travelynx)
* [GitHub](https://github.com/derf/travelynx)
