# Account Migration

If you decide to set up your own travelynx instance, you can migrate all trips that you have stored on travelynx.de (or any other instance) to it.

Please note that **you must have admin access to the target instance**, and running the import requires read access to your complete user data export.
As such, migrating to your own (or a trusted friend's) instance works, but migrating back to, e.g., travelynx.de is not supported (yet).
Web-based migration / import without jumping through CLI hoops may or may not follow in the future.

## Requirements

* An up-to-date [stops.csv](https://travelynx.de/static/stops.csv) dump from the source instance.
* An up-to-date [user data export](https://travelynx.de/account) (“travelynx-export-*username*-*date*.json”) from the source instance.
* The ability to run `perl index.pl import` commands on the target instance.

## How-To

* Create an account on the target instance and note down its *Account ID* as shown on the profile page.
* Run `perl index.pl import stops stops.csv`
* Run `perl index.pl import journeys` *AccountID* *AccountName* `stops.csv travelynx-export-`*username*`-`*date*`.json`

## Background

Logged trips reference numeric stop IDs.
For DBRIS, EFA, HAFAS and IRIS backends, those are identical to the numeric stop IDs used within the backend itself.
For MOTIS backends, stop IDs are *instance-specific* and map to string identifiers used within the corresponding backend.
travelynx calls the former “eva” and the latter “external\_id” or extID.

So, in order for an import to work, there are two requirements:

* The target instance must know all stops used within your trips.
* When importing, numeric stop IDs used for MOTIS trips must be mapped from the IDs on the source instanece to the corresponding IDs on the target instance.
  These are typically *not* identical, but can be mapped via the source instance's stops.csv export and (slow) extID lookups on the target instance.

The `import journeys` command takes care of this.
It may take a while to do so, though.
