function tvly_run(link, req, redir, err_callback) {
	var error_icon = '<i class="material-icons">error</i>';
	var progressbar = $('<div class="progress"><div class="indeterminate"></div></div>');
	link.hide();
	link.after(progressbar);
	$.post('/action', req, function(data) {
		if (data.success) {
			$(location).attr('href', redir);
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
$(document).ready(function() {
	$('.action-checkin').click(function() {
		var link = $(this);
		var req = {
			action: 'checkin',
			station: link.data('station'),
			train: link.data('train'),
		};
		tvly_run(link, req, '/');
	});
	$('.action-checkout').click(function() {
		var link = $(this);
		var req = {
			action: 'checkout',
			station: link.data('station'),
			force: link.data('force'),
		};
		tvly_run(link, req, '/' + req.station, function() {
			link.append(' – Keine Echtzeitdaten vorhanden')
			link.data('force', true);
		});
	});
	$('.action-undo').click(function() {
		var link = $(this);
		var req = {
			action: 'undo',
		};
		tvly_run(link, req, window.location.href);
	});
});
