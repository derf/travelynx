/*
 * Copyright (C) 2020 Birte Kristina Friesel
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
document.addEventListener('DOMContentLoaded', () => {
	const getPlaceholder = () => document.querySelector('div.geolocation div.progress');

	const createTableRow = (ds100, name, hafas) => {
		const node = document.createElement('a');
		node.classList.add('tablerow');
		node.setAttribute('href', `/s/${ds100}?hafas=${hafas}`);

		const icon = (parseInt(hafas)) ? "directions" : "train";
		node.innerHTML = `<span><i class="material-icons" aria-hidden="true">${icon}</i>${name}</span>`;

		node.addEventListener('click', () => document.querySelector("nav .preloader-wrapper").classList.add('active'));

		return node;
	};
	const showError = (header, message, code) => {
		const errnode = document.createElement('div');
		errnode.classList.add('error');
		errnode.innerText = message;

		const headnode = document.createElement('strong');
		headnode.innerText = header + ' ';
		errnode.prepend(headnode);

		document.querySelector('.geolocation').append(errnode);

		const recent = document.querySelector('.geolocation').dataset.recent;
		if (!recent) {
			getPlaceholder().remove();
			return;
		}

		const stops = recent.split('|');
		const res = document.createElement('p');
		for (const stop of stops) {
			const [ds100, name, hafas] = stop.split(';');
			const node = createTableRow(ds100, name, hafas);
			res.append(node);
		}

		document.querySelector('p.geolocationhint').innerText = 'Letzte Ziele:';
		getPlaceholder().replaceWith(res);
	};

	const processResult = ({ error, candidates }) => {
		if (error) {
			showError('Backend-Fehler:', error, null);
			return;
		}

		if (!candidates.length) {
			showError('Keine Bahnhöfe in 70km Umkreis gefunden', '', null);
			return;
		}

		const res = document.createElement('p');
		for (const candidate of candidates) {
			const { eva, name, hafas } = candidate;
			const node = createTableRow(eva, name, hafas);
			res.appendChild(node);
		}
		getPlaceholder().replaceWith(res);
	};

	const processLocation = ({ coords }) => {
		fetch('/geolocation', {
			method: 'POST',
			headers: {
				'Content-Type': 'application/json',
			},
			body: JSON.stringify({
				lon: coords.longitude,
				lat: coords.latitude,
			}),
		})
			.then((resp) => resp.json())
			.then(processResult);
	};

	const processError = function(error) {
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

	const geolocationButton = document.querySelector('.geolocation > button');
	const getGeoLocation = function() {
		geolocationButton.replaceWith('<p class="geolocationhint">Stationen in der Umgebung:</p><div class="progress"><div class="indeterminate"></div></div>');
		navigator.geolocation.getCurrentPosition(processLocation, processError);
	};

	if (!navigator.geolocation) {
		showError('Standortanfragen werden von diesem Browser nicht unterstützt', '', null);
		return;
	}

	// We have the geolocation feature, but without the permissions.
	// That means, we can just fetch the location on the button click.
	if (!navigator.permissions) {
		geolocationButton.addEventListener('click', getGeoLocation);
		return;
	}

	navigator.permissions.query({ name: 'geolocation' }).then(({ state }) => {
		if (state === 'prompt') {
			geolocationButton.addEventListener('click', getGeoLocation);
			return;
		}

		// User either rejected or granted permissions. Therefore they won't get prompted and we can show stations/error.
		getGeoLocation();
	});
});
