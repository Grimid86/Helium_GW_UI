'use strict';
'require baseclass';
return baseclass.extend({
	title: _('LoRa Packet Forwarder'),
	load: function() {
		return fetch(L.url('admin/services/lora/api/status'), { credentials: 'same-origin' }).then(function(res) {
			if (!res.ok) return {};
			return res.json();
		}).catch(function(err) { return {}; });
	},
	render: function(data) {
		if (!data || !data.region) return null;
		var statusColor = data.running ? '#4caf50' : '#f44336';
		var statusText = data.running ? _('Running') : _('Stopped');
		var table = E('table', { 'class': 'table' });
		var rows = [
			[_('Status'), E('span', { style: 'color:' + statusColor + ';font-weight:bold;' }, statusText)],
			[_('Region'), data.region || '-'],
			[_('Gateway ID'), E('span', { style: 'font-family:monospace;' }, data.gateway_id || '-')],
			[_('Server'), data.server_address || '-'],
			[_('Port Up/Down'), (data.server_port_up || '-') + ' / ' + (data.server_port_down || '-')],
			[_('Board Temperature'), (data.temperature !== undefined ? data.temperature.toFixed(1) + ' °C' : '-')],
			[_('RX Packets'), data.rx_packets_total !== undefined ? data.rx_packets_total : '-'],
			[_('TX Packets'), data.tx_packets !== undefined ? data.tx_packets : '-'],
			[_('Forwarded'), data.rx_forwarded !== undefined ? data.rx_forwarded : '-'],
			[_('ACK Rate'), (data.push_ack_percent !== undefined ? data.push_ack_percent.toFixed(0) + '%' : '-')],
			[_('Latitude'), (data.ref_latitude !== undefined ? data.ref_latitude : '-')],
			[_('Longitude'), (data.ref_longitude !== undefined ? data.ref_longitude : '-')],
			[_('Altitude (m)'), (data.ref_altitude !== undefined ? data.ref_altitude : '-')],
			[_('Max TX Power'), (data.max_tx_power !== undefined ? data.max_tx_power + ' dBm' : '-')],
			[_('Antenna Gain'), (data.antenna_gain !== undefined ? data.antenna_gain + ' dBi' : '-')],
		];
		for (var i = 0; i < rows.length; i++) {
			table.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, [rows[i][0]]),
				E('td', { 'class': 'td left' }, [rows[i][1]])
			]));
		}
		var link = E('div', { style: 'margin-top:0.5em;' }, [
			E('a', { href: L.url('admin/services/lora/status'), class: 'cbi-button cbi-button-action' }, _('Open LoRa Settings'))
		]);
		return E('div', {}, [table, link]);
	}
});
