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
		setTimeout(tvly_update, 20000);
	}).fail(function() {
		$('.sync-failed-marker').css('display', 'block');
		setTimeout(tvly_update, 20000);
	});
}
function tvly_update_public() {
	var user_name;
	$('.publicstatuscol').each(function() {
		user_name = $(this).data('user');
	});
	$.get('/ajax/status/' + user_name + '.html', function(data) {
		$('.publicstatuscol').html(data);
		setTimeout(tvly_update_public, 20000);
	}).fail(function() {
		$('.sync-failed-marker').css('display', 'block');
		setTimeout(tvly_update_public, 20000);
	});
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
}
$(document).ready(function() {
	tvly_reg_handlers();
	if ($('.statuscol .autorefresh').length) {
		setTimeout(tvly_update, 20000);
	}
	if ($('.publicstatuscol .autorefresh').length) {
		setTimeout(tvly_update_public, 20000);
	}
	$('a[href]').click(function() {
		$('nav .preloader-wrapper').addClass('active');
	});
});
