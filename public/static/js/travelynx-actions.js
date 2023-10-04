/*
 * Copyright (C) 2020 Birte Kristina Friesel
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
var j_departure = 0;
var j_duration = 0;
var j_arrival = 0;
var j_dest = '';
var j_stops = [];
var j_token = '';
function upd_journey_data() {
	const countdowns = document.querySelectorAll('.countdown');
	for (const c of countdowns) {
		const { token, journey, dest, route } = c.dataset;
		if (token) j_token = token;

		if (journey) {
			const [departure, arrival] = journey.split(';');
			j_duration = departure - arrival;
		}

		if (dest) j_dest = dest;

		if (route) {
			const stops = route.split('|');
			j_stops = [];
			for (const stop of stops) {
				const stopdata = stop.split(';');
				for (let i = 1; i < 5; i++) stopdata[i] = parseInt(stopdata[i]);

				j_stops.push(stopdata);
			}
		}
	}
}
function upd_countdown() {
	const now = Date.now() / 1000;
	const countdownEl = document.querySelector('.countdown');
	if (j_departure > now) {
		countdownEl.innerText = 'Abfahrt in ' + Math.round((j_departure - now) / 60) + ' Minuten';
		return;
	}

	if (j_arrival <= now) {
		countdownEl.innerText = 'Ziel erreicht';
		return;
	}

	const diff = Math.round((j_arrival - now) / 60);
	if (diff >= 120) {
		countdownEl.innerText = 'Ankunft in ' + Math.floor(diff / 60) + ' Stunden und ' + (diff % 60) + ' Minuten';
	} else if (diff >= 60) {
		countdownEl.innerText = 'Ankunft in 1 Stunde und ' + (diff % 60) + ' Minuten';
	} else {
		countdownEl.innerText = 'Ankunft in ' + diff + ' Minuten';
	}
}
function hhmm(epoch) {
	const date = new Date(epoch * 1000);
	const h = date.getHours();
	const m = date.getMinutes();
	return (h < 10 ? '0' + h : h) + ':' + (m < 10 ? '0' + m : m);
}
function odelay(sched, rt) {
	if (sched < rt) {
		return ' (+' + (rt - sched) / 60 + ')';
	} else if (sched == rt) {
		return '';
	}
	return ' (' + (rt - sched) / 60 + ')';
}

function tvly_run(link, req, err_callback) {
	const error_icon = '<i class="material-icons">error</i>';
	let progressbar;
	if (link.dataset.tr) {
		progressbar = '<tr><td colspan="' + link.dataset.tr + '"><div class="progress"><div class="indeterminate"></div></div></td></tr>';
	} else {
		progressbar = '<div class="progress"><div class="indeterminate"></div></div>';
	}
	link.style.display = 'none';
	link.after(progressbar);
	fetch('/action', { method: 'POST' }).then(async (resp) => {
		if (!resp.ok) return;

		const { success, redirect_to, error } = await resp.json();
		if (success) {
			window.location.href = redirect_to;
			return;
		}

		M.toast({ html: error_icon + ' ' + error });
		progressbar.remove();
		if (err_callback) err_callback();
		link.append(' ' + error_icon);
		link.style.display = 'block';
	});
}
function tvly_update() {
	fetch('/ajax/status_card.html').then(async (resp) => {
		if (!resp.ok) {
			document.querySelector('.sync-failed-marker').style.display = 'block';
			upd_countdown();
			setTimeout(tvly_update, 5000);
			return;
		}

		document.querySelector('.statuscol').innerHTML = await resp.text();
		tvly_reg_handlers();
		upd_journey_data();
		setTimeout(tvly_update, 40000);
	});
}
function tvly_update_public() {
	let userName,
		profileStatus = 0;
	document.querySelectorAll('.publicstatuscol').forEach((node) => {
		userName = node.dataset.user;
		profileStatus = parseInt(node.dataset.profile);
	});

	fetch(`/ajax/status/${userName}.html`, {
		headers: { 'content-type': 'application/json' },
		body: JSON.stringify({ token: j_token, profile: profileStatus }),
	}).then(async (resp) => {
		if (!resp.ok) {
			document.querySelector('.sync-failed-marker').style.display = 'block';
			upd_countdown();
			setTimeout(tvly_update_public, 5000);
			return;
		}

		document.querySelector('.publicstatuscol').innerHTML = await resp.text();
		upd_journey_data();
		setTimeout(tvly_update_public, 40000);
	});
}
function tvly_update_timeline() {
	fetch('/timeline/in-transit', {
		headers: { 'content-type': 'application/json' },
		body: `{"ajax": 1}`,
	}).then((resp) => {
		if (!resp.ok) {
			document.querySelector('.sync-failed-marker').style.display = 'block';
			setTimeout(tvly_update_timeline, 10000);
			return;
		}
	});
}
function tvly_journey_progress() {
	const now = Date.now() / 1000;
	let progress = 0;
	if (j_duration <= 0) return;

	progress = 1 - (j_arrival - now) / j_duration;
	if (progress < 0) progress = 0;
	if (progress > 1) progress = 1;

	document.querySelector('.progress .determinate').style.width = `${progress * 100}%`;

	const nextStopEl = document.querySelector('.next-stop');
	for (const stop of j_stops) {
		const [stop_name, sched_arr, rt_arr, sched_dep, rt_dep] = stop;
		if (stop_name == j_dest) {
			nextStopEl.innerHTML = '';
			break;
		}
		if (rt_arr != 0 && rt_arr - now > 0) {
			nextStopEl.innerHTML = `${stop_name}<br/>${hhmm(rt_arr)}${odelay(sched_arr, rt_arr)}`;
			break;
		}
		if (rt_dep != 0 && rt_dep - now > 0) {
			nextStopEl.innerHTML = `${stop_name}<br/>${hhmm(rt_arr)} → ${hhmm(rt_dep)}${odelay(sched_dep, rt_dep)}`;
			break;
		}
	}
	setTimeout(tvly_journey_progress, 5000);
}
function tvly_reg_handlers() {
	document.querySelector('.action-checkin').addEventListener('click', (ev) => {
		const link = ev.currentTarget;
		const { station, train, dest } = link.dataset;
		tvly_run(link, {
			action: 'checkin',
			station,
			train,
			dest,
		});
	});
	document.querySelector('.action-checkout').addEventListener('click', (ev) => {
		const link = ev.currentTarget;
		const { station, force } = link.dataset;
		tvly_run(link, { action: 'checkout', station, force }, () => {
			if (!force || force === 'false') {
				link.append(' – Ohne Echtzeitdaten auschecken?');
				link.dataset.force = 'true';
			}
		});
	});
	document.querySelector('.action-undo')?.addEventListener('click', (ev) => {
		const link = ev.currentTarget;
		let { id, checkints } = link.dataset;
		checkints = parseInt(checkints);

		const now = Date.now() / 1000;

		let doCheckout = true;
		if (now - checkints > 900) {
			doCheckout = confirm('Checkin wirklich rückgängig machen? Er kann ggf. nicht wiederholt werden.');
		}
		if (!doCheckout) return;
		tvly_run(link, {
			action: 'undo',
			undo_id: id,
		});
	});
	document.querySelector('.action-cancelled-from')?.addEventListener('click', (ev) => {
		const link = ev.currentTarget;
		const { station, train } = link.dataset;
		tvly_run(link, { action: 'cancelled_from', station, train });
	});
	document.querySelector('.action-cancelled-to')?.addEventListener('click', (ev) => {
		const link = ev.currentTarget;
		tvly_run(link, {
			action: 'cancelled_to',
			station: link.dataset.station,
			force: true,
		});
	});
	document.querySelector('.action-delete')?.addEventListener('click', (ev) => {
		const link = ev.currentTarget;
		const { id, checkin, checkout } = link.dataset;
		const req = {
			action: 'delete',
			id,
			checkin,
			checkout,
		};
		const really_delete = confirm('Diese Zugfahrt wirklich löschen? Der Eintrag wird sofort aus der Datenbank entfernt und kann nicht wiederhergestellt werden.');
		if (really_delete) {
			tvly_run(link, req);
		}
	});
	document.querySelector('.action-share')?.addEventListener('click', (ev) => {
		const link = ev.currentTarget;
		let { text, url } = link.dataset;

		if (navigator.share) {
			let shareObj = { text };
			if (url) shareObj = { text, url };
			navigator.share(shareObj);
			return;
		}

		const el = document.createElement('textarea');
		if (url) {
			text += ' ' + url;
		}
		el.value = text;
		el.setAttribute('readonly', '');
		el.style.position = 'absolute';
		el.style.left = '-9999px';
		document.body.appendChild(el);
		el.select();
		el.setSelectionRange(0, 99999);
		document.execCommand('copy');
		document.body.removeChild(el);
		M.toast({ html: `Text kopiert: „${text}“` });
	});
}
document.addEventListener('DOMContentLoaded', () => {
	tvly_reg_handlers();
	if (document.querySelector('.statuscol .autorefresh')) {
		upd_journey_data();
		setTimeout(tvly_update, 40000);
		setTimeout(tvly_journey_progress, 5000);
	}
	if (document.querySelector('.publicstatuscol .autorefresh')) {
		upd_journey_data();
		setTimeout(tvly_update_public, 40000);
		setTimeout(tvly_journey_progress, 5000);
	}
	if (document.querySelector('.timeline-in-transit .autorefresh')) {
		setTimeout(tvly_update_timeline, 60000);
	}
	document.querySelectorAll('a[href]').forEach(() => document.querySelector('nav .preloader-wrapper')?.classList.add('active'));
	const elems = document.querySelectorAll('.carousel');
	M.Carousel.init(elems, {
		fullWidth: true,
		indicators: true,
	});
});
