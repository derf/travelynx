$(document).ready(function() {
	$('.action-checkin').click(function() {
		var link = $(this);
		req = {
			action: 'checkin',
			station: link.data('station'),
			train: link.data('train'),
		};
		link.replaceWith('<div class="progress"><div class="indeterminate"></div></div>');
		$.post('/action', req, function(data) {
			$(location).attr('href', '/');
		});
	});
	$('.action-checkout').click(function() {
		var link = $(this);
		req = {
			action: 'checkout',
			station: link.data('station'),
			force: link.data('force'),
		};
		link.replaceWith('<div class="progress"><div class="indeterminate"></div></div>');
		$.post('/action', req, function(data) {
			$(location).attr('href', '/' + req.station);
		});
	});
});
