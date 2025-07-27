# travelynx primer

For the sake of this manual, we will assume your travelynx instance is running
on `travelynx.de`

travelynx journey logging is based on checkin and checkout actions: You check
into a train when boarding it, select a destination, and are automatically
checked out when you arrive. Real-time data is saved on both occasions and
continuously updated while in transit, providing an accurate overview of both
scheduled and actual journey times.

## Checking in

You can check into a train at nearly any point in time, though it's usually a
good idea to do it within a 30-minute window befor/after its departure. The
precise constraints depend on the selected backend (i.e., data provider).

First, you need to select the stop you want to check in from.  Navigate to
`travelynx.de` or click/tap on the travelynx text in the navigation bar. You
will see a list of the five stops closest to your current location (as reported
by your browser). Select the stop you're at or enter its name manually.

As soon as you select a train, you will be checked in and travelynx will switch
to the journey / checkout view. If you already know where you're headed, you
should click/tap on the destination stop in the stop list now. You can change
the destination by selecting a new one anytime.

## Checking out

You are automatically checked out a few minutes after arrival at your
destination. If the train has already arrived when you select a destination and
its arrival was less than two hours ago, you are checked out immediately.  If
it's more than two hours, you need to perform a manual checkout (without
arrival data) using the link at the bottom of the checkin menu's stop list.
