function httpcall(link, cb, silent) {
	var x = new XMLHttpRequest(),
	    l = document.getElementById('loader'),
	    b = document.getElementById('banner'),
	    ln = l.nextElementSibling,
	    bn = b.nextElementSibling;

	if (!silent) {
		ln.parentNode.removeChild(l);
		l.classList.add('open');
		ln.parentNode.insertBefore(l, ln);
	}

	x.onreadystatechange = function() {
		if (x.readyState == 4) {
			var rv = cb(x),
			    ok = true,
			    msg = 'Action completed';

			if (rv === false || rv === null || rv === undefined) {
				ok = false;
				msg = 'Action failed';
			}
			else if (rv === true) {
				ok = true;
				msg = '';
			}
			else if (Array.isArray(rv)) {
				ok = rv[0],
				msg = rv[1];
			}

			if (msg) {
				bn.parentNode.removeChild(b);

				if (ok)
					b.classList.remove('error');
				else
					b.classList.add('error');

				b.innerText = msg;
				b.classList.add('open');
				bn.parentNode.insertBefore(b, bn);
			}

			l.classList.remove('open');
		}
	};

	x.open('GET', link);
	x.send();
}

function esc(s) {
	return (s || '').replace(/&/g, '&amp;')
	                .replace(/</g, '&lt;')
	                .replace(/>/g, '&gt;')
	                .replace(/"/g, '&quot;')
}

function duration(s) {
	var d = (s || 0).toString().split(/,/),
	    ss = d[0] || 0,
	    us = d[1] || 0;
	return '' +
		''.substr.call( 100 + ss / 3600,      1, 2) + ':' +
		''.substr.call( 100 + ss % 3600 / 60, 1, 2) + ':' +
		''.substr.call( 100 + ss % 60,        1, 2) + '.' +
		''.substr.call(1000 + us / 1000,      1, 3)
	;
}

function attachEvents(nodes, events, func) {
	if (!nodes || !events || !func)
		return;

	if (typeof(nodes) === 'string')
		nodes = document.querySelectorAll(nodes);
	else if (!Array.isArray(nodes))
		nodes = [ nodes ];

	if (typeof(events) === 'string')
		events = events.split(/\s+/);

	for (var i = 0, node; node = nodes[i]; i++)
		for (var j = 0, event; event = events[j]; j++)
			if (typeof(node) === 'object' && node.addEventListener)
				node.addEventListener(event, func, false);
}

function findMovieInfo(elem) {
	while (elem && elem.getAttribute) {
		var info = elem.getAttribute('data-info');
		if (info)
			return JSON.parse(info);

		elem = elem.parentNode;
	}

	return null;
}

function addMovie(elem, autoplay) {
	var info = findMovieInfo(elem),
	    parent = findParentNode('[data-info]', elem);

	if (parent.classList.contains('disabled'))
		return;

	httpcall('/add/' + encodeURIComponent(info.path), function(response) {
		if (response.status === 200) {
			info = JSON.parse(response.responseText);

			if (autoplay && info) {
				window.currentMedia = info;
				openMovie();
			}

			parent.classList.add('disabled');
			return [true, 'Movie "' + (info.meta ? info.meta.name : info.name) + '" added to playlist.'];
		} else {
			return [false, 'Incompatible media file!'];
		}
	});

	return false;
}

function deleteMovie(elem) {
	var info = findMovieInfo(elem),
	    parent = findParentNode('[data-info]', elem);

	if (!info || !parent)
		return;

	parent.classList.add('disabled');

	httpcall('/delete/' + info.serverid, function(response) {
		if (response.status === 200) {
			parent.parentNode.removeChild(parent);
			return [true, 'Movie removed.'];
		} else {
			return [false, 'Unable to delete movie!'];
		}
	});

	return false;
}

function openMovie(elem) {
	var p = document.getElementById('player'),
	    n = p.nextElementSibling,
	    h = p.querySelector('h2'),
	    a = p.querySelector('audio'),
	    v = p.querySelector('video'),
	    list = p.querySelector('.playlist[opened]'),
	    prev = p.querySelector('[data-action=prev-movie]'),
	    next = p.querySelector('[data-action=next-movie]'),
	    seek = p.querySelector('[data-action=seekable-movie]');

    var info = findMovieInfo(elem) || window.currentMedia;

	if (!info)
		return;

	closeInfo();

	if (list) list.removeAttribute('opened');

	if (elem && findParentNode('.active', elem)) {
		(a.style.display !== 'none') ? a.play() : v.play();
		return;
	}

	window.currentMedia = info;

	n.parentNode.removeChild(p);

	p.classList.add('open');
	h.innerText = (info.meta && info.meta.name) ? info.meta.name : info.name;
	seek.style.display = (info.transcoding_status === 'complete') ? 'none' : '';
	n.parentNode.insertBefore(p, n);
	document.body.classList.add('modal');

	v.style.maxWidth = v.parentNode.offsetWidth + 'px';
	v.style.maxHeight = v.parentNode.offsetHeight + 'px';

	if (info.meta && info.meta['tracks-video'] && info.meta['tracks-video'].length) {
		p.style.backgroundImage = '';

		a.src = '';
		a.style.display = 'none';

		v.src = '/' + encodeURIComponent(info.serverid) + '/stream.m3u8';
		v.style.display = '';
		v.style.backgroundImage = 'url(/thumbnail/' + encodeURIComponent(info.link) + ')';
		v.load();
		v.play();
	} else {
		p.style.backgroundImage = 'url(/resource/audio.png)';

		a.src = '/' + encodeURIComponent(info.serverid) + '/stream.m3u8';
		a.style.display = '';
		a.load();
		a.play();

		v.src = '';
		v.style.display = 'none';
	}

	return false;
}

function closeMovie()
{
	var p = document.getElementById('player'),
	    a = p.querySelector('audio'),
	    v = p.querySelector('video');

	a.pause();
	a.currentTime = 0;

	v.pause();
	v.currentTime = 0;

	p.classList.remove('open');
	document.body.classList.remove('modal');

	window.currentMedia = null;
}

function seekableMovie(elem)
{
	var p = document.getElementById('player'),
	    a = p.querySelector('audio'),
	    v = p.querySelector('video');

    if (!window.currentMedia)
		return;

	var media = (a.style.display !== 'none') ? a : v,
	    time = media.currentTime;

	media.src = '/' + window.currentMedia.serverid + '/' +
		(window.currentMedia.seekable ? 'stream.m3u8' : 'seekable.m3u8');

	media.currentTime = time;
	media.load();
	media.play();

	window.currentMedia.seekable = !window.currentMedia.seekable;
	elem.innerText = window.currentMedia.seekable ? ' ∞ ' : '«»';
}

function prevMovie()
{
	if (!window.currentMedia)
		return;

	var p = document.getElementById('player'),
	    r = p.querySelector('[data-action=prev-movie]'),
	    n = p.querySelector('[data-action=next-movie]');

	r.classList.add('disabled');

	httpcall('/prev/' + window.currentMedia.serverid, function(response) {
		var json = (response.status === 200) ? JSON.parse(response.responseText) : null;
		if (json) {
			window.currentMedia = json;
			openMovie();
			r.classList.remove('disabled');
			n.classList.remove('disabled');
		}
		return true;
	});
}

function nextMovie()
{
	if (!window.currentMedia)
		return;

	var p = document.getElementById('player'),
	    r = p.querySelector('[data-action=prev-movie]'),
	    n = p.querySelector('[data-action=next-movie]');

	n.classList.add('disabled');

	httpcall('/next/' + window.currentMedia.serverid, function(response) {
		var json = (response.status === 200) ? JSON.parse(response.responseText) : null;
		if (json) {
			window.currentMedia = json;
			openMovie();
			r.classList.remove('disabled');
			n.classList.remove('disabled');
		}
		return true;
	});
}

function openInfo(elem)
{
	var i = document.getElementById('info'),
	    n = i.nextElementSibling,
	    h = i.querySelector('h2'),
	    m = i.querySelector('dl'),
	    t = i.querySelector('img');

	var info = findMovieInfo(elem) || window.currentMedia;

	if (!info)
		return;

	window.currentMedia = info;

	n.parentNode.removeChild(i);

	i.classList.add('open');
	m.innerHTML = '';
	h.innerText = (info.meta && info.meta.name) ? info.meta.name : info.name;
	t.style.display = '';
	t.src = '/thumbnail/' + info.link;

	var s = '';

	if (info.meta) {
		s += '<dt><strong>Name:</strong> ' + esc(info.meta.name || info.name) + '</dt>';
		s += '<dt><strong>Path:</strong> ' + esc(info.meta.uri || '?') + '</dt>';
		s += '<dt><strong>Duration:</strong> ' + duration(info.meta.duration) + '</dt>';

		if (info.meta['tracks-video'] && info.meta['tracks-video'].length) {
			s += '<dt><strong>Video:</strong><dl>';

			for (var tn = 0; t = info.meta['tracks-video'][tn]; tn++) {
				var k = Object.keys(t).sort();
				for (var kn = 0; kn < k.length; kn++) {
					if (k[kn] === 'Type' || k[kn] === 'track')
						continue;

					s += '<dt><strong>' + esc(k[kn]) + ':</strong> ' + esc(t[k[kn]]) + '</dt>';
				}
			}

			s += '</dl></dt>';
		}

		if (info.meta['tracks-audio'] && info.meta['tracks-audio'].length) {
			s += '<dt><strong>Audio:</strong><dl>';

			for (var tn = 0; t = info.meta['tracks-audio'][tn]; tn++) {
				var k = Object.keys(t).sort();
				for (var kn = 0; kn < k.length; kn++) {
					if (k[kn] === 'Type' || k[kn] === 'track')
						continue;

					s += '<dt><strong>' + esc(k[kn]) + ':</strong> ' + esc(t[k[kn]]) + '</dt>';
				}
			}

			s += '</dl></dt>';
		}
	}

	m.innerHTML = s;

	n.parentNode.insertBefore(i, n);
	document.body.classList.add('modal');
}

function closeInfo()
{
	var i = document.getElementById('info');

	i.classList.remove('open');
	document.body.classList.remove('modal');
}

function loadPlaylist(ev)
{
	var self = this,
	    p = document.getElementById('player'),
	    a = p.querySelector('audio')
	    v = p.querySelector('video');

	self.classList.add('loading');

	if (p.classList.contains('open') && self.id !== 'playlist') {
		a.pause();
		v.pause();
	}

	httpcall('/playlist', function(response) {
		self.classList.remove('loading');

		if (response.status === 200) {
			try {
				var json = JSON.parse(response.responseText);
				var list = '';

				for (var i = 0, item; item = json.playlist[i]; i++) {
					var active = (window.currentMedia && window.currentMedia.serverid === item.serverid) ? 'active' : '';

					list += '' +
						'<li class="' + active + '" id="' + esc(item.serverid) + '" data-info="' + esc(JSON.stringify(item)) + '" draggable>' +
							'<span class="t" style="background-image:url(&quot;/thumbnail/' + encodeURIComponent(item.link) + '&quot;)">' +
								'<img src="/resource/play.png" data-action="open-movie">' +
							'</span>' +
							'<span class="b">' +
								'<strong>' + esc(item.meta.name || item.name) + '</strong><br>' +
								duration(item.meta.duration) +
								(item.transcoding_status === 'complete' ? '' : ' (transcoding: ' + duration(item.transcoding_duration) + ')') +
							'</span>' +
							'<nav>' +
								'<span class="i" data-action="start-drag">&nbsp;↕&nbsp;</span>' +
								'<span class="g" data-action="open-info">Info</span>' +
								'<span class="r" data-action="delete-movie">Delete</span>' +
							'</nav>' +
							'<span data-open>…</span>' +
						'</li>'
					;
				}

				self.innerHTML = '<ul>' + list + '</ul>';

				var active = self.querySelector('.active');
				if (active) active.scrollIntoView();

				return true;
			}
			catch(e) {
				return [false, 'Invalid playlist data'];
			}
		}

		return [false, response.statusText];
	}, true);
}

function dragStart(ev)
{
	ev.dataTransfer.setData("text", ev.target.id);
}

function dragOver(ev)
{
	if (ev.currentTarget.nodeName === 'LI') {
		ev.currentTarget.style.opacity = 0.5;
		ev.preventDefault();
	}
}

function dragOut(ev)
{
	if (ev.currentTarget.nodeName === 'LI') {
		ev.currentTarget.style.opacity = '';
		ev.preventDefault();
	}
}

function dragEnd(ev)
{
	ev.preventDefault();

	var node = document.getElementById(ev.dataTransfer.getData("text")),
	    next = ev.currentTarget;

	while (next) {
		if (next === node)
			break;

		next = next.nextElementSibling;
	}

	if (next)
		ev.currentTarget.parentNode.insertBefore(node, ev.currentTarget);
	else if (ev.currentTarget.nextElementSibling)
		ev.currentTarget.parentNode.insertBefore(node, ev.currentTarget.nextElementSibling);
	else
		ev.currentTarget.parentNode.appendChild(node);

	ev.currentTarget.style.opacity = '';
}

function handleTouchMove(ev) {
	if (ev.touches.length !== 1)
		return;

	var touch = ev.touches[0],
	    drag = window.dragState;

	if (!drag) {
		var node = findParentNode('[draggable]', touch.target);

		if (!node)
			return;

		drag = window.dragState = {
			y: touch.screenY,
			node: node,
			offset: Math.floor(node.offsetHeight / 2),
			ghost: document.createElement('div')
		};

		drag.node.style.animation = 'none';

		drag.ghost.className = 'ghost';
		drag.ghost.style.left = node.offsetLeft + 'px';
		drag.ghost.style.width = node.offsetWidth + 'px';
		drag.ghost.style.height = node.offsetHeight + 'px';
		drag.ghost.style.marginTop = -drag.offset + 'px';
		drag.ghost.innerHTML = node.outerHTML;

	    document.body.appendChild(drag.ghost);
	}

	drag.ghost.style.top = touch.screenY + 'px';

	var dropables = document.querySelectorAll('[drop-above], [drop-below]');
	for (var i = 0, dropable; dropable = dropables[i]; i++) {
		dropable.removeAttribute('drop-above');
		dropable.removeAttribute('drop-below');
	}

	var scrollParent = findParentNode(function(n) {
		return n.offsetHeight < n.scrollHeight; },
	drag.node) || document.body;

	var deltaY = touch.clientY - drag.y,
	    minY = touch.clientY - drag.offset,
	    maxY = minY + drag.offset * 2;

	if (deltaY < 0 && minY <= 50)
		scrollParent.scrollTop -= 10;
	else if (deltaY > 0 && maxY >= window.innerHeight - 50)
		scrollParent.scrollTop += 10;

	var target = findParentNode('[draggable]',
		document.elementFromPoint(touch.screenX, touch.screenY - window.pageYOffset));

	if (target) {
		var node = drag.node.nextElementSibling ? drag.node : null;

		while (node) {
			if (node === target)
				break;

			node = node.nextElementSibling;
		}

		target.setAttribute(node ? 'drop-below' : 'drop-above', true);
	}

	drag.y = touch.clientY;
	drag.target = target;

	ev.preventDefault();
}

function handleTouchEnd(ev) {
	if (ev.changedTouches.length !== 1)
		return;

	var drag = window.dragState;

	if (!drag)
		return;

	if (drag.target) {
		if (drag.target.getAttribute('drop-above'))
			drag.target.parentNode.insertBefore(drag.node, drag.target);
		else if (drag.target.nextElementSibling)
			drag.target.parentNode.insertBefore(drag.node, drag.target.nextElementSibling);
		else
			drag.target.parentNode.appendChild(drag.node);

		drag.target.removeAttribute('drop-above');
		drag.target.removeAttribute('drop-below');

		drag.node.removeAttribute('opened');
		drag.node.style.animation = 'highlight 1s 1';

		httpcall('/move/' + drag.node.id + '/' + (drag.node.nextElementSibling ? drag.node.nextElementSibling.id : ''),
		    function(response) {
				if (response.status === 200) {
					return true;
				} else {
					return [false, 'Failed to save playlist'];
				}
	    	});
	}

	drag.ghost.parentNode.removeChild(drag.ghost);
	window.dragState = null;
}

function findParentNode(cmp, node) {
	while (node) {
		if ((typeof(cmp) === 'string' && node.matches && node.matches(cmp)) ||
		    (typeof(cmp) === 'function' && cmp(node)) ||
		    (node === cmp))
			return node;

		node = node.parentNode;
	}

	return null;
}

document.addEventListener('DOMContentLoaded', function(ev) {
	attachEvents(window, 'click touchstart', function(ev) {
		var opened = document.querySelectorAll('[opened]');

		var open = ev.target.getAttribute('data-open');
		if (typeof(open) === 'string') {
			var elem = (open !== '') ? document.querySelector(open) : ev.target.parentNode;
			if (elem) {
				var init = elem.getAttribute('data-init');
				if (typeof(init) === 'string' && typeof(window[init]) === 'function')
					window[init].call(elem, ev);
				elem.setAttribute('opened', true);
			}
		}

		switch (ev.target.getAttribute('data-action')) {
		case 'open-info':
			openInfo(ev.target);
			ev.preventDefault();
			break;

		case 'close-info':
			closeInfo(ev.target);
			ev.preventDefault();
			break;

		case 'open-movie':
			openMovie(ev.target);
			ev.preventDefault();
			break;

		case 'close-movie':
			closeMovie(ev.target);
			ev.preventDefault();
			break;

		case 'add-movie':
			addMovie(ev.target);
			ev.preventDefault();
			break;

		case 'play-movie':
			addMovie(ev.target, true);
			ev.preventDefault();
			break;

		case 'delete-movie':
			deleteMovie(ev.target);
			ev.preventDefault();
			break;

		case 'prev-movie':
			prevMovie(ev.target);
			ev.preventDefault();
			break;

		case 'next-movie':
			nextMovie(ev.target);
			ev.preventDefault();
			break;

		case 'seekable-movie':
			seekableMovie(ev.target);
			ev.preventDefault();
			break;

		case 'start-drag':
			ev.preventDefault();
			break;
		}

		for (var i = 0; i < opened.length; i++) {
			if (findParentNode(opened[i], ev.target)) {
				continue;
			}
			opened[i].removeAttribute('opened');
		}
	});

	attachEvents(window, 'touchmove', function(ev) {
		if (ev.target.matches('[data-action=start-drag]'))
			return handleTouchMove(ev);
	});

	attachEvents(window, 'touchend', function(ev) {
		if (findParentNode('[draggable]', ev.target))
			return handleTouchEnd(ev);
	});

	attachEvents('audio, video', 'ended', function(ev) {
		if (!window.currentMedia)
			return;

		httpcall('/next/' + window.currentMedia.serverid, function(response) {
			var json = (response.status === 200) ? JSON.parse(response.responseText) : null;
			window.currentMedia = json;
			openMovie();
		});
	});

	var plist = document.getElementById('playlist');

	loadPlaylist.call(plist);

	window.setInterval(function() {
		if (document.body.classList.contains('modal') ||
	        plist.querySelector('[opened]') ||
	        window.dragState)
			return;

		loadPlaylist.call(plist);
	}, 1000 * 5);
});
