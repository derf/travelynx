$(document).ready(function() {
	var error_icon = '<i class="material-icons">error</i>';
	$('.action-checkin').click(function() {
		var link = $(this);
		req = {
			action: 'checkin',
			station: link.data('station'),
			train: link.data('train'),
		};
		progressbar = $('<div class="progress"><div class="indeterminate"></div></div>');
		link.replaceWith(progressbar);
		$.post('/action', req, function(data) {
			if (data.success) {
				$(location).attr('href', '/');
			} else {
				M.toast({html: error_icon + ' ' + data.error});
				link.append(' ' + error_icon);
				progressbar.replaceWith(link);
			}
		});
	});
	$('.action-checkout').click(function() {
		var link = $(this);
		req = {
			action: 'checkout',
			station: link.data('station'),
			force: link.data('force'),
		};
		progressbar = $('<div class="progress"><div class="indeterminate"></div></div>');
		link.replaceWith(progressbar);
		$.post('/action', req, function(data) {
			if (data.success) {
				$(location).attr('href', '/' + req.station);
			} else {
				M.toast({html: error_icon + ' ' + data.error});
				link.append(' ' + error_icon);
				progressbar.replaceWith(link);
			}
		});
	});
});
