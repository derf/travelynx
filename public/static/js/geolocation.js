/*
 * Copyright (C) 2020 Daniel Friesel
 *
 * SPDX-License-Identifier: MIT
 */
$(document).ready(function() {
	function getPlaceholder() {
		return $('div.geolocation div.progress');
	}
	var showError = function(header, message, code) {
		getPlaceholder().remove();
		var errnode = $(document.createElement('div'));
		errnode.attr('class', 'error');
		errnode.text(message);

		var headnode = $(document.createElement('strong'));
		headnode.text(header);
		errnode.prepend(headnode);

		$('div.geolocation').append(errnode);
	};

	var processResult = function(data) {
		if (data.error) {
			showError('Backend-Fehler:', data.error, null);
		} else if (data.candidates.length == 0) {
			showError('Keine Bahnhöfe in 70km Umkreis gefunden', '', null);
		} else {
			resultTable = $('<table><tbody></tbody></table>')
			resultBody = resultTable.children();
			$.each(data.candidates, function(i, candidate) {

				var ds100 = candidate.ds100,
					name = candidate.name,
					distance = candidate.distance;
				distance = distance.toFixed(1);

				var stationlink = $(document.createElement('a'));
				stationlink.attr('href', ds100);
				stationlink.text(name);

				resultBody.append('<tr><td><a href="/s/' + ds100 + '">' + name + '</a></td></tr>');
			});
			getPlaceholder().replaceWith(resultTable);
		}
	};

	var processLocation = function(loc) {
		$.post('/geolocation', {lon: loc.coords.longitude, lat: loc.coords.latitude}, processResult);
	};

	var processError = function(error) {
		if (error.code == error.PERMISSION_DENIED) {
			showError('Standortanfrage nicht möglich.', 'Vermutlich fehlen die Rechte im Browser oder der Android Location Service ist deaktiviert.', 'geolocation.error.PERMISSION_DENIED');
		} else if (error.code == error.POSITION_UNAVAILABLE) {
			showError('Standort konnte nicht ermittelt werden', '(Service nicht verfügbar)', 'geolocation.error.POSITION_UNAVAILABLE');
		} else if (error.code == error.TIMEOUT) {
			showError('Standort konnte nicht ermittelt werden', '(Timeout)', 'geolocation.error.TIMEOUT');
		} else {
			showError('Standort konnte nicht ermittelt werden', '(unbekannter Fehler)', 'unknown geolocation.error code');
		}
	};

	var geoLocationButton = $('div.geolocation > button');
	var getGeoLocation = function() {
		geoLocationButton.replaceWith($('<p class="geolocationhint">Stationen in der Umgebung:</p><div class="progress"><div class="indeterminate"></div></div>'));
		navigator.geolocation.getCurrentPosition(processLocation, processError);
	}

	if (geoLocationButton.length) {
		if (navigator.geolocation) {
			if (navigator.permissions) {
				navigator.permissions.query({ name:'geolocation' }).then(function(value) {
					if (value.state === 'prompt') {
						geoLocationButton.on('click', getGeoLocation);
					} else {
						// User either rejected or granted permission. User wont get prompted and we can show stations/error
						getGeoLocation();
					}
				});
			} else {
				geoLocationButton.on('click', getGeoLocation);
			}
		} else {
			showError('Standortanfragen werden von diesem Browser nicht unterstützt', '', null);
		}
	}
});
