var j_duration = 0;
var j_arrival = 0;
function upd_journey_data() {
	$('.countdown').each(function() {
		j_duration = $(this).data('duration');
		j_arrival = $(this).data('arrival');
	});
}
function upd_countdown() {
	var now = Date.now() / 1000;
	if (j_arrival > 0) {
		if (j_arrival > now) {
			$('.countdown').text('Ankunft in ' + Math.round((j_arrival - now)/60) + ' Minuten');
		} else {
			$('.countdown').text('Ziel erreicht');
		}
	}
}
function tvly_run(link, req, err_callback) {
	var error_icon = '<i class="material-icons">error</i>';
	var progressbar = $('<div class="progress"><div class="indeterminate"></div></div>');
	link.hide();
	link.after(progressbar);
	$.post('/action', req, function(data) {
		if (data.success) {
			$(location).attr('href', data.redirect_to);
		} else {
			M.toast({html: error_icon + ' ' + data.error});
			progressbar.remove();
			if (err_callback) {
				err_callback();
			}
			link.append(' ' + error_icon);
			link.show();
		}
	});
}
function tvly_update() {
	$.get('/ajax/status_card.html', function(data) {
		$('.statuscol').html(data);
		tvly_reg_handlers();
		upd_journey_data();
		setTimeout(tvly_update, 40000);
	}).fail(function() {
		$('.sync-failed-marker').css('display', 'block');
		upd_countdown();
		setTimeout(tvly_update, 5000);
	});
}
function tvly_update_public() {
	var user_name;
	$('.publicstatuscol').each(function() {
		user_name = $(this).data('user');
	});
	$.get('/ajax/status/' + user_name + '.html', function(data) {
		$('.publicstatuscol').html(data);
		upd_journey_data();
		setTimeout(tvly_update_public, 40000);
	}).fail(function() {
		$('.sync-failed-marker').css('display', 'block');
		upd_countdown();
		setTimeout(tvly_update_public, 5000);
	});
}
function tvly_journey_progress() {
	var now = Date.now() / 1000;
	var progress = 0;
	if (j_duration > 0) {
		progress = 1 - ((j_arrival - now) / j_duration);
		if (progress < 0) {
			progress = 0;
		}
		if (progress > 1) {
			progress = 1;
		}
		$('.progress .determinate').css('width', (progress * 100) + '%');
		setTimeout(tvly_journey_progress, 5000);
	}
}
function tvly_reg_handlers() {
	$('.action-checkin').click(function() {
		var link = $(this);
		var req = {
			action: 'checkin',
			station: link.data('station'),
			train: link.data('train'),
		};
		tvly_run(link, req);
	});
	$('.action-checkout').click(function() {
		var link = $(this);
		var req = {
			action: 'checkout',
			station: link.data('station'),
			force: link.data('force'),
		};
		tvly_run(link, req, function() {
			link.append(' – Ohne Echtzeitdaten auschecken?')
			link.data('force', true);
		});
	});
	$('.action-undo').click(function() {
		var link = $(this);
		var req = {
			action: 'undo',
			undo_id: link.data('id'),
		};
		tvly_run(link, req);
	});
	$('.action-cancelled-from').click(function() {
		var link = $(this);
		var req = {
			action: 'cancelled_from',
			station: link.data('station'),
			train: link.data('train'),
		};
		tvly_run(link, req);
	});
	$('.action-cancelled-to').click(function() {
		var link = $(this);
		var req = {
			action: 'cancelled_to',
			station: link.data('station'),
			force: true,
		};
		tvly_run(link, req);
	});
	$('.action-delete').click(function() {
		var link = $(this);
		var req = {
			action: 'delete',
			id: link.data('id'),
			checkin: link.data('checkin'),
			checkout: link.data('checkout'),
		};
		really_delete = confirm("Diese Zugfahrt wirklich löschen? Der Eintrag wird sofort aus der Datenbank entfernt und kann nicht wiederhergestellt werden.");
		if (really_delete) {
			tvly_run(link, req);
		}
	});
	$('.action-share').click(function() {
		if (navigator.share) {
			shareObj = {
				text: $(this).data('text')
			};
			if ($(this).data('url')) {
				shareObj['url'] = $(this).data('url');
			}
			navigator.share(shareObj);
		}
	});
	if ($('.action-share').length && !navigator.share) {
		$('.action-share').css('display', 'none');
	}
}
$(document).ready(function() {
	tvly_reg_handlers();
	if ($('.statuscol .autorefresh').length) {
		upd_journey_data();
		setTimeout(tvly_update, 40000);
		setTimeout(tvly_journey_progress, 5000);
	}
	if ($('.publicstatuscol .autorefresh').length) {
		upd_journey_data();
		setTimeout(tvly_update_public, 40000);
		setTimeout(tvly_journey_progress, 5000);
	}
	$('a[href]').click(function() {
		$('nav .preloader-wrapper').addClass('active');
	});
});
