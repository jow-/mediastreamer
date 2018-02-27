function httpcall(link, cb) {
	var x = new XMLHttpRequest(),
	    l = document.getElementById('loader'),
	    b = document.getElementById('banner'),
	    ln = l.nextElementSibling,
	    bn = b.nextElementSibling;

	ln.parentNode.removeChild(l);
	l.classList.add('open');
	ln.parentNode.insertBefore(l, ln);

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
	var d = (s || '0,0').split(/,/),
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

function findParent(elem) {
	while (elem) {
		if (elem.getAttribute('data-info'))
			return elem;

		elem = elem.parentNode;
	}

	return null;
}

function addMovie(elem, autoplay) {
	var info = findMovieInfo(elem),
	    parent = findParent(elem);

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
	var info = findMovieInfo(elem);
	var parent = findParent(elem);

	if (!info || !parent)
		return;

	parent.classList.add('disabled');

	httpcall('/delete/' + info.serverid, function(response) {
		if (response.status === 200) {
			return [true, 'Movie removed.'];
			parent.parentNode.removeChild(parent);
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
	    next = p.querySelector('[data-action=next-movie]');

    var info = findMovieInfo(elem) || window.currentMedia;

	if (!info)
		return;

	closeInfo();

	if (list) list.removeAttribute('opened');

	if (!window.currentMedia || info.serverid !== window.currentMedia.serverid) {
		window.currentMedia = info;

		httpcall('/prev/' + info.serverid, function(response) {
			var json = (response.status === 200) ? JSON.parse(response.responseText) : null;
			window.currentMedia.prev = json;
			prev.style.display = json ? '' : 'none';
			return true;
		});

		httpcall('/next/' + info.serverid, function(response) {
			var json = (response.status === 200) ? JSON.parse(response.responseText) : null;
			window.currentMedia.next = json;
			next.style.display = json ? '' : 'none';
			return true;
		});

		n.parentNode.removeChild(p);

		p.classList.add('open');
		h.innerText = (info.meta && info.meta.name) ? info.meta.name : info.name;
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
	}
	else {
		a.src ? a.play() : v.play();
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

	window.currentMedia = null;
}

function loadPlaylist(ev)
{
	var self = this;
	self.classList.add('loading');

	httpcall('/playlist', function(response) {
		self.classList.remove('loading');

		if (response.status === 200) {
			try {
				var json = JSON.parse(response.responseText);
				var list = '';

				for (var i = 0, item; item = json.playlist[i]; i++) {
					var active = (window.currentMedia && window.currentMedia.serverid === item.serverid) ? 'active' : '';

					list += '' +
						'<li class="' + active + '" data-info="' + esc(JSON.stringify(item)) + '">' +
							'<span class="t" style="background-image:url(&quot;/thumbnail/' + encodeURIComponent(item.link) + '&quot;)">' +
								'<img src="/resource/play.png" data-action="open-movie">' +
							'</span>' +
							'<span class="b">' +
								'<strong>' + esc(item.meta.name || item.name) + '</strong><br>' +
								duration(item.meta.duration || '0,0') +
							'</span>' +
						'</li>'
					;
				}

				self.innerHTML = '<ul>' + list + '</ul>';
				self.querySelector('.active').scrollIntoView();

				return true;
			}
			catch(e) {
				return [false, 'Invalid playlist data'];
			}
		}

		return [false, response.statusText];
	});
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
		var node = touch.target;

		while (node && (!node.getAttribute || !node.getAttribute('draggable')))
			node = node.parentNode;

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

	var deltaY = touch.screenY - drag.y,
	    minY = (touch.screenY - window.pageYOffset - drag.offset),
	    maxY = minY + drag.offset * 2;

	if (deltaY < 0 && minY <= 50)
		window.scrollBy(0, -10);
	else if (deltaY > 0 && maxY >= window.innerHeight - 50)
		window.scrollBy(0, 10);

	var target = document.elementFromPoint(touch.screenX, touch.screenY - window.pageYOffset);

	while (target && (!target.getAttribute || !target.getAttribute('draggable')))
		target = target.parentNode;

	if (target) {
		var node = drag.node.nextElementSibling ? drag.node : null;

		while (node) {
			if (node === target)
				break;

			node = node.nextElementSibling;
		}

		target.setAttribute(node ? 'drop-below' : 'drop-above', true);
	}

	drag.y = touch.screenY;
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

document.addEventListener('DOMContentLoaded', function(ev) {
	attachEvents(window, 'click touchstart', function(ev) {
		var opened = document.querySelector('[opened]');
		if (opened) {
			var node = ev.target;

			while (node) {
				if (node === opened)
					break;
				node = node.parentNode;
			}

			if (!node)
				opened.removeAttribute('opened');
		}

		var open = ev.target.getAttribute('data-open');
		if (typeof(open) === 'string') {
			var elem = (open !== '') ? document.querySelector(open) : ev.target.parentNode;
			if (elem) {
				var init = elem.getAttribute('data-init');
				if (typeof(init) === 'string' && typeof(window[init]) === 'function')
					window[init].call(elem, ev);
				elem.setAttribute('opened', true);
			}
			ev.preventDefault();
			return;
		}

		switch (ev.target.getAttribute('data-action')) {
		case 'open-info':
			openInfo(ev.target);
			break;

		case 'close-info':
			closeInfo(ev.target);
			break;

		case 'open-movie':
			openMovie(ev.target);
			break;

		case 'close-movie':
			closeMovie(ev.target);
			break;

		case 'add-movie':
			addMovie(ev.target);
			break;

		case 'play-movie':
			addMovie(ev.target, true);
			break;

		case 'delete-movie':
			deleteMovie(ev.target);
			break;

		case 'prev-movie':
			if (window.currentMedia)
				window.currentMedia = window.currentMedia.prev;
			openMovie(ev.target);
			break;

		case 'next-movie':
			if (window.currentMedia)
				window.currentMedia = window.currentMedia.next;
			openMovie(ev.target);
			break;

		default:
			return;
		}

		ev.preventDefault();
	});

	attachEvents('[drag-handle]', 'touchmove', handleTouchMove);
	attachEvents('[draggable]',   'touchend',  handleTouchEnd);

	attachEvents('audio, video', 'ended', function(ev) {
		if (window.currentMedia && window.currentMedia.next) {
			window.currentMedia = window.currentMedia.next;
			openMovie(ev.target);
		}
	});
});
