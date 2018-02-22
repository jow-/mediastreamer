#!/usr/bin/env perl
#
# Copyright 2018 Jo-Philipp Wich <jo@mein.io>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

use strict;
use warnings;

use Cwd;
use JSON;
use IO::Select;
use Digest::MD5;
use HTTP::Daemon;
use URI::QueryParam;
use File::Temp;
use POSIX ':sys_wait_h';

my $local_port = $ARGV[0] || 51544;
my $root_dir = Cwd::realpath($ARGV[1] || $ENV{HOME} . '/Downloads');
my $cache_dir = "/tmp/.streamer_cache";
my $vlc_exe = "/usr/bin/vlc";

$SIG{'PIPE'} = 'IGNORE';

if (defined($ARGV[0]) && ($ARGV[0] eq '-h' || $ARGV[0] eq '--help')) {
	die "Usage: $0 [listen-port] [media-directory]\n";
}

my $daemon = HTTP::Daemon->new(
	LocalPort => $local_port,
	LocalAddr => '0.0.0.0',
	ReuseAddr => 1,
	Listen    => 30
) || die "Unable to instantiate daemon: $!\n";

sub json_write($$)
{
	my ($path, $object) = @_;

	if (open J, '>', $path) {
		print J JSON->new->utf8->encode($object);
		close J;

		return 1;
	}

	warn "Unable to write file $path: $!\n";
	return 0;
}

sub json_read($)
{
	my ($path) = @_;

	if (open J, '<', $path) {
		local $/;
		my $object;

		eval {
			$object = JSON->new->utf8->decode(readline J);
		};

		if ($@) {
			warn "Unable to decode JSON: $@\n";
		}

		close J;

		return $object;
	}

	warn "Unable to read file $path: $!\n";
	return 0;
}

sub reply_json($$;$)
{
	my ($client, $object, $header) = @_;

	if (!defined($header) || ref($header) ne 'ARRAY') {
		$header = [
			'Content-Type' => 'application/json; charset=UTF-8'
		];
	}

	my $response = HTTP::Response->new(200, "OK", $header,
	                                   JSON->new->utf8->encode($object));

	warn sprintf "R: %s\n", $response->content;

	return $client->send_response($response);
}

sub exec_cmd
{
	my ($client, @cmd) = @_;
	my ($out, $pid, $ro, $re, $wo, $we);

	warn "X: @cmd\n";

	if (!pipe($ro, $wo)) {
		warn "Unable to spawn pipe: $!\n";
		return ();
	}

	if (!pipe($re, $we)) {
		warn "Unable to spawn pipe: $!\n";
		close($ro);
		close($wo);
		return ();
	}

	$pid = fork;

	if (!defined $pid) {
		warn "Unable to fork child: $!\n";
		close($ro);
		close($wo);
		close($re);
		close($we);
		return ();
	}

	if ($pid == 0) {
		close($daemon);
		close($client);
		open(STDOUT, ">&", $wo);
		open(STDERR, ">&", $we);
		close(STDIN);
		close($ro);
		close($wo);
		close($re);
		close($we);
		exec(@cmd);
		exit -1;
	}

	close($wo);
	close($we);

	my $s = IO::Select->new($ro, $re);

	while (1) {
		my @fds = $s->can_read(10);

		if (!@fds) {
			warn "Command timed out\n" if $s->count > 0;
			kill $pid;
			last;
		}

		foreach my $fd (@fds) {
			my ($len, $buf);

			$len = $fd->sysread($buf, 1024);

			if ($len <= 0) {
				$s->remove($fd);
			}
			else {
				$out = '' unless defined $out;
				$out .= $buf;
			}
		}
	}

	waitpid($pid, 0);

	close($ro);
	close($re);

	return split /\r?\n/, $out;
}

sub vlc_transcode($$)
{
	my ($client, $params) = @_;

	my $keyframe  = $params->{keyframe}  || '';
	my $file      = $params->{file}      || '';
	my $width     = $params->{width}     || '';
	my $clientid  = $params->{clientid}  || '';
	my $type      = $params->{type}      || '';
	my $good      = $params->{good}      || '';
	my $date      = $params->{date}      || '';
	my $set       = $params->{set}       || '';
	my $ab        = $params->{ab}        || '';
	my $vb        = $params->{vb}        || '';
	my $name      = $params->{name}      || '';
	my $framerate = $params->{framerate} || '';

	unless ($type      eq 'file' &&
	        $file      =~ m!^.+$! && -f $file &&
	        $date      =~ m!^\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d\d\d\d$! &&
	        length($name) && length($good) && length($set) && length($clientid) &&
	        $ab        =~ m!^\d+$! && $ab > 0 &&
	        $vb        =~ m!^\d+$! && $vb > 0 &&
	        $width     =~ m!^\d+$! && $width > 0 &&
	        $keyframe  =~ m!^\d+$! && $keyframe > 0)
	{
		return (undef, "Invalid parameters given");
	}

	my ($basename) = $file =~ m!/([^/]+?)\.[^.]+$!;
	my $workdir = "$cache_dir/$basename";

	unless (-f "$workdir/stream.m3u8") {
		if (system('mkdir', '-p', $workdir) != 0) {
			return (undef, "Unable to mkdir: $!");
		}
		else {
			$workdir = Cwd::realpath($workdir);
		}

		my $seglen = 10;
		my $senc = 'Windows-1252';
		my $sout =
			'--sout=#transcode{' .
				'vcodec=h264,soverlay,acodec=aac,channels=2,venc=x264{' .
					'hrd=vbr,profile=baseline,level=3,preset=fast,' .
					"keyint=$keyframe," .
					'ref=1,' .
					"vbv-maxrate=$vb,vbv-bufsize=$vb" .
				'},' .
				"width=$width," .
				'deinterlace,' .
				"ab=$ab" .
			'}:std{' .
				'access=livehttp{' .
					"seglen=$seglen," .
					"index=\"$workdir/stream.m3u8\"," .
					'index-url=stream-###.ts' .
				'},' .
				'mux=ts{use-key-frames},' .
				"dst=\"$workdir/stream-###.ts\"" .
			'}'
		;

		my @cmd = ($vlc_exe,
			qw(--ignore-config -I dummy --no-sout-all),
			$file, 'vlc://quit', $sout,
			"--subsdec-encoding=$senc",
			qw(--sout-avcodec-strict=-2 -vvv --extraintf=logger --file-logging),
			"--logfile=$workdir/encode.log");

		my $pid = fork;

		if (!defined $pid) {
			return (undef, "Unable to fork: $!");
		}

		if ($pid == 0) {
			$daemon->close;
			$client->close;

			POSIX::setsid();

			my $vlcpid = fork;

			if (!defined $vlcpid) {
				exit -1;
			}

			if ($vlcpid == 0) {
				open(STDOUT, '>', '/dev/null');
				open(STDERR, '>', '/dev/null');
				close(STDIN);
				exec(@cmd);
				exit(-1);
			}

			open(P, '>', "$workdir/encode.pid");
			print P $vlcpid;
			close P;

			waitpid $vlcpid, 0;

			if ($? == 0) {
				open(C, '>', "$workdir/complete.txt");
				close(C);
				unlink("$workdir/encode.pid");
			}

			exit $?;
		}

		json_write("$workdir/params.txt", {
			command              => "create2",
			usehelpersettings    => "1",
			'--subsdec-encoding' => $senc,
			sout                 => $sout,
			seglen               => $seglen,

			date      => $date,
			type      => $type,
			name      => $name,
			file      => $file,

			clientid  => $clientid,
			serverid  => sprintf('%08x', rand(0xffffffff)),
			processid => $pid,

			good      => $good,
			set       => $set,

			ab        => $ab,
			vb        => $vb,
			width     => $width,
			keyframe  => $keyframe,
			framerate => $framerate
		});
	}

	return (1, "encoding started");
}

sub vlc_thumbnail($$)
{
	my ($client, $file) = @_;
	my $cache = sprintf '%s/thumbs/%s.png', $cache_dir, Digest::MD5::md5_hex($file);

	if (system('mkdir', '-p', "$cache_dir/thumbs") != 0) {
		warn "Unable to create thumbnail directory: $!\n";
		return undef;
	}

	if (open C, '<', $cache) {
		local $/;
		my $data = readline C;
		close C;
		return $data;
	}

	(my $dur = vlc_info($client, $file, 'duration') || '') =~ s![^0-9].*$!.0!;
	my $pos = ($dur < 121) ? int($dur * 0.25) : 121;

	my $dir = File::Temp->newdir;
	my @cmd = ($vlc_exe,
		qw(--ignore-config -I dummy -V dummy -A dummy
		   --no-video-title --no-media-library --avcodec-hw=off
		   --rate=1 --video-filter=scene --scene-format=png --scene-ratio=24),
		"--start-time=$pos", "--stop-time=".($pos+1),
		"--scene-path=$dir", $file, 'vlc://quit');

	exec_cmd($client, @cmd);

	my $snap;

	if (opendir D, $dir) {
		while (defined(my $entry = readdir D)) {
			my $file = "$dir/$entry";
			next unless -f $file;
			$snap = $file if !defined($snap) || $file gt $snap;
		}
		closedir D;
	}

	if ($snap) {
		if (open S, '<', $snap) {
			local $/;
			my $data = readline S;
			close S;

			if (open C, '>', $cache) {
				print C $data;
				close C;
			}

			return $data;
		}
	}
	else {
		warn "Unable to generate snapshot of '$file'\n";
	}

	return pack 'H*',
		'89504e470d0a1a0a0000000d4948445200000004000000030806000000b4f4aec60000' .
		'000c4944415408d763602019000000330001567d830a0000000049454e44ae426082'
	;
}

sub vlc_info($$;$)
{
	my ($client, $file, $field) = @_;
	my @cmd = ($vlc_exe,
		qw(--ignore-config -I luaintf --lua-intf dumpmeta -V dummy -A dummy
		   --no-video-title --no-media-library),
		$file, 'vlc://quit');

	my (%info, @streams, $stream);

	foreach my $line (exec_cmd($client, @cmd)) {
		if ($line =~ m!\blua interface: +(name|uri|duration|encoded_by|filename): (.+)$!) {
			if (defined($field) && $1 eq $field) {
				return $2;
			}

			$info{$1} = $2;
		}
		elsif ($line =~ m!\blua interface: +Stream (\d+)$!) {
			$stream = $streams[$1] = {};
		}
		elsif ($stream && $line =~ m!\blua interface: +([^:]+): (.+)$!) {
			$stream->{$1} = $2;
		}
	}

	for (my $i = 0; $i < @streams; $i++) {
		$streams[$i]{track} = $i;
		$streams[$i]{Language} ||= 'English';

		if ($streams[$i]{Type} eq 'Audio') {
			push @{$info{'tracks-audio'}}, $streams[$i];
		}
		elsif ($streams[$i]{Type} eq 'Video') {
			push @{$info{'tracks-video'}}, $streams[$i];
		}
	}

	return \%info;
}

sub cache_etag
{
	my $md5 = Digest::MD5->new;
	my @entries;

	if (opendir C, $cache_dir) {
		while (defined(my $entry = readdir C)) {
			if ($entry ne '.' && $entry ne '..') {
				push @entries, $entry;
			}
		}
		closedir C;
	}

	@entries = sort @entries;

	foreach my $entry (@entries) {
		my $mtime = (stat "$cache_dir/$entry/stream.m3u8")[9];
		if (defined($mtime)) {
			$md5->add($entry);
			$md5->add($mtime);
		}
	}

	return ($md5->hexdigest, @entries);
}

sub encoding_status($)
{
	my ($movie) = @_;

	if (-s "$cache_dir/$movie/stream.m3u8") {
		my $max_segment = 1;
		while (1) {
			my $segment = sprintf("$cache_dir/$movie/stream-%03d.ts", $max_segment++);
			next if -f $segment;
			last;
		}

		if (-f "$cache_dir/$movie/complete.txt") {
			return ('complete', $max_segment - 1);
		}
		else {
			return (sprintf('segments-%d', $max_segment - 1), $max_segment - 1);
		}
	}

	return ('segments-0', 0);
}

sub delete_cache($$)
{
	my ($client, $id) = @_;
	my $found = 0;

	if (!defined($id) || !length($id)) {
		return (undef, "Invalid parameters given");
	}

	if (opendir D, $cache_dir) {
		while (defined(my $entry = readdir D)) {
			my $params = "$cache_dir/$entry/params.txt";
			next unless -f $params;

			my $json = json_read($params);
			next if ref($json) ne 'HASH' || $json->{serverid} ne $id;

			my $pid = -1;
			if (open P, '<', "$cache_dir/$entry/encode.pid") {
				if (defined(my $line = readline P)) {
					if ($line =~ m!^(\d+)$!) {
						$pid = $1;
					}
				}
				close P;
			}

			if ($pid > -1) {
				kill('TERM', $pid);
			}

			if (system('rm', '-r', "$cache_dir/$entry") != 0) {
				warn "Unable to purge cache directory for id $id\n";
			}

			$found++;
			last;
		}

		closedir D;
	}

	if ($found) {
		return (1, "Movie deleted");
	}
	else {
		return (undef, "Unable to find movie");
	}
}

sub path_rel($$)
{
	my ($root, $path) = @_;

	if (!defined($root) || !defined($path)) {
		return undef;
	}

	$root = Cwd::realpath($root);
	$path = Cwd::realpath($path);

	if ($path eq $root) {
		return '/';
	}

	if (length($path) < length($root) ||
		index($path, $root) != 0 ||
		substr($path, length($root), 1) ne '/') {
		return undef;
	}

	return substr($path, length($root));
}

sub path_abs($$)
{
	my ($root, $path) = @_;

	if (!defined($root) || !defined($path)) {
		return undef;
	}

	$path = Cwd::realpath("$root/$path");

	if (path_rel($root, $path)) {
		return $path;
	}

	return undef;
}

sub html_esc($)
{
	my ($s) = @_;
	$s =~ s/([<>&"])/sprintf '&#%d;', ord $1/eg
		if defined $s;
	return $s;
}

sub url_enc($)
{
	my ($s) = @_;
	$s =~ s!([^a-zA-Z0-9_./-])!sprintf '%%%02x', ord $1!eg
		if defined $s;
	return $s;
}

sub url_dec($)
{
	my ($s) = @_;
	$s =~ s!%([a-fA-F0-9][a-fA-F0-9])!chr hex $1!eg
		if defined $s;
	return $s;
}

sub handle_movies($$)
{
	my ($client, $request) = @_;
	my ($cache_etag, @entries) = cache_etag();
	my $client_etag = $request->header('If-None-Match');

	if (defined($client_etag) && $client_etag eq $cache_etag) {
		return $client->send_response(HTTP::Response->new(304, "No changes", [
			'Content-Type' => 'application/json; charset=UTF-8',
			'ETag'         => $cache_etag
		]));
	}

	my @movies;

	foreach my $entry (@entries) {
		my $params = "$cache_dir/$entry/params.txt";
		next unless -f "$cache_dir/$entry/params.txt";

		my $json = json_read($params);
		next unless ref($json) eq 'HASH' && $json->{name} && $json->{type} eq 'file';

		push @movies, {
			name => $entry,
			params => $json,
			status => encoding_status($entry),
			serverId => $json->{serverid},
			displayedName => $json->{name}
		};
	}

	return reply_json($client, { movies => \@movies }, [
		'Content-Type' => 'application/json; charset=UTF-8',
		'ETag'         => $cache_etag
	]);
}

sub handle_browse($$)
{
	my ($client, $request) = @_;
	my $dir = $request->uri->query_param('dir');
	my @entries;

	if (opendir D, $dir) {
		while (defined(my $entry = readdir D)) {
			next if $entry eq '.' || $entry eq '..';

			my $path = Cwd::realpath("$dir/$entry");

			if (-d $path) {
				push @entries, {
					type => "dir",
					name => $entry,
					path => $path
				};
			}
			elsif (-f $path) {
				push @entries, {
					type => "file",
					name => $entry,
					path => $path
				};
			}
		}

		closedir D;
	}

	return reply_json($client, {
		files => \@entries,
		root  => Cwd::realpath($dir)
	});
}

sub handle_getpath($$)
{
	my ($client, $request) = @_;
	my $dir = $request->uri->query_param('dir');

	if ($dir eq '...home...') {
		return reply_json($client, { root => $root_dir });
	}
	elsif ($dir eq '...drives...') {
		return reply_json($client, { root => "/" });
	}
	else {
		warn "Unknown path type: " . $dir . "\n";
		return reply_json($client, {
			errorMessage => "Unknown directory type '$dir'",
			result => ""
		});
	}
}

sub handle_info($$)
{
	my ($client, $request) = @_;
	my $file = $request->uri->query_param('file');
	my $info = vlc_info($client, $file);
	return reply_json($client, $info);
}

sub handle_create2($$)
{
	my ($client, $request) = @_;
	my ($ok, $error) = vlc_transcode($client, {
		keyframe  => $request->uri->query_param('keyframe'),
		file      => $request->uri->query_param('file'),
		width     => $request->uri->query_param('width'),
		clientid  => $request->uri->query_param('clientid'),
		type      => $request->uri->query_param('type'),
		good      => $request->uri->query_param('good'),
		date      => $request->uri->query_param('date'),
		set       => $request->uri->query_param('set'),
		ab        => $request->uri->query_param('ab'),
		vb        => $request->uri->query_param('vb'),
		name      => $request->uri->query_param('name'),
		framerate => $request->uri->query_param('framerate'),
	});

	if ($ok) {
		return reply_json($client, { errorMessage => "", result => "encoding started" });
	}
	else {
		return reply_json($client, { errorMessage => $error, result => "" });
	}
}

sub handle_delete($$)
{
	my ($client, $request) = @_;
	my ($ok, $error) = delete_cache($client, $request->uri->query_param('id'));

	if ($ok) {
		return reply_json($client, { errorMessage => "", result => "movie deleted" });
	}
	else {
		return reply_json($client, { errorMessage => $error, result => "" });
	}
}

sub handle_file($$)
{
	my ($client, $request) = @_;
	my $path = path_abs($cache_dir, url_dec($request->uri->path));

	if (defined($path) && -f $path) {
		if ($path =~ m!/stream\.m3u8$! && $request->uri->query_param('seekable')) {
			my $data = '';
			if (open F, '<', $path) {
				local $/;
				$data = readline F;
				$data =~ s!^#EXT-X-PLAYLIST-TYPE:EVENT\b!#EXT-X-PLAYLIST-TYPE:VOD!;
				$data .= "\n#EXT-X-ENDLIST\n" unless $data =~ m!^#EXT-X-ENDLIST\b!;
				close F;

				warn "S: $path\n";
				return $client->send_response(HTTP::Response->new(200, "OK", [
					'Content-Type' => 'application/vnd.apple.mpegurl'
				], $data));
			}
			else {
				return $client->send_error(500, 'Unable to process playlist');
			}
		}

		warn "F: $path\n";
		return $client->send_file_response($path);
	}

	warn sprintf "404: %s (%s)\n", $path || '?', $request->uri->path;
	return $client->send_error(404, 'No such file or directory');
}

sub handle_index($$)
{
	my ($client, $request) = @_;
	my ($etag, @entries) = cache_etag();

	my $dir = $request->uri->query_param('dir');
	my $thumb = $request->uri->query_param('thumbnail');
	my $movie = $request->uri->query_param('movie');
	my $stream = $request->uri->query_param('stream');
	my $delete = $request->uri->query_param('delete');
	my $json = $movie ? json_read("$cache_dir/$movie/params.txt") : undef;

	my $page = qq{
		<html>
			<head>
				<title>iOS Streaming</title>
				<meta name="viewport" content="width=device-width, initial-scale=1.0">
				<style type="text/css">
					body {
						font-family: sans-serif;
						font-size: 120%;
						margin: 0;
						padding: .5em;
					}

					ul {
						display: flex;
						flex-direction: column;
						padding: 0;
						list-style: none;
						width: 100%;
					}

					a {
						text-decoration: none;
						color: inherit;
					}

					li {
						display: flex;
						margin: .25em;
					}

					.b {
						flex-grow: 4;
						background: #ccc;
						color: #444;
						overflow: hidden;
						text-overflow: ellipsis;
						white-space: nowrap;
						padding: .5em;
					}

					.r, .i, .g {
						justify-content: flex-end;
						background: #f44;
						color: #fff;
						font-weight: bold;
						padding: .5em;
						flex-basis: 20%;
						text-align: center;
						overflow: hidden;
						text-overflow: ellipsis;
						white-space: nowrap;
					}

					.i {
						background: #44e;
					}

					.g {
						background: #494;
					}

					.t {
						flex-basis: 4em;
						background: #ccc;
						background-size: 100% 100%;
					}

					h1 {
						font-size: 120%;
					}

					header, nav {
						display: flex;
						margin: 1em 0;
					}

					header > :first-child::before {
						content: "";
					}

					header > ::before {
						content: "» ";
						font-weight: bold;
					}

					header > *, nav > * {
						margin: 0;
						padding: .25em;
						flex-basis: auto !important;
						white-space: nowrap;
						overflow: hidden;
						text-overflow: ellipsis;
					}

					header {
						line-height: 2em;
						margin: -.5em -.5em .5em -.5em;
						background: #000;
						color: #fff;
					}

					nav > * {
						margin: 0 .5em 0 0;
					}
				</style>
			</head>
			<body>
	};

	if ($dir) {
		my $path = path_abs($root_dir, $dir);
		my $up   = path_rel($root_dir, path_abs($root_dir, "$dir/.."));

		$page .= sprintf q{
			<header>
				<h1><a href="/">iOS Streaming</a></h1>
				<span>%s</span>
			</header>
		}, path_rel($root_dir, $path);

		if (opendir P, $path) {
			if ($up) {
				$page .= sprintf q{
					<li>
						<a class="b" href="/?dir=%s">../</a>
				        <em class="i">parent</em>
				    </li>
				}, url_enc($up);
			}

			my (@dirs, @files);
			while (defined(my $entry = readdir P)) {
				my $file = "$path/$entry";

				if (-d $file && $entry ne '.' && $entry ne '..') {
					push @dirs, $entry;
				}
				elsif (-f $file && $entry =~ m!\.(mp4|mov|ogg|flv|wmv|avi)$!i) {
					push @files, $entry;
				}
			}

			closedir P;

			foreach my $entry (sort @dirs) {
				$page .= sprintf q{
					<li>
						<a class="b" href="/?dir=%s">%s/</a>
				        <em class="i">directory</em>
				    </li>
				}, url_enc(path_rel($root_dir, "$path/$entry")),
				   html_esc($entry);
			}

			foreach my $entry (sort @files) {
				my $file = path_rel($root_dir, "$path/$entry");

				$page .= sprintf q{
					<li>
						<span class="t" style="background-image:url(/?thumbnail=%s)">&nbsp;</span>
				        <a class="b" href="/?stream=%s">%s</a>
				        <span class="i">%.02f MB</span>
				    </li>
				}, url_enc($file),
				   url_enc($file),
				   html_esc($entry),
				   (stat "$path/$entry")[7] / 1024 / 1024;
			}
		}

		$page .= '</ul><nav>';

		if ($up) {
			$page .= sprintf q{
				<a class="i" href="/?dir=%s">&laquo; Parent directory</a>
			}, url_enc($up);
		}

		$page .= '<a class="r" href="/">Overview &raquo;</a></nav>';
	}
	elsif ($thumb) {
		my $path = path_abs($root_dir, $thumb);
		if ($path) {
			my $data = vlc_thumbnail($client, $path);
			if ($data) {
				return $client->send_response(HTTP::Response->new(200, "OK", [
					'Content-Type'  => 'image/png',
					'Expires'       => POSIX::strftime('%a, %e %b %Y %H:%M:%S %Z', localtime(time() + 30758400)),
					'Cache-Control' => 'max-age=30758400'
				], $data));
			}
		}

		return $client->send_error(404, 'No such file or directory');
	}
	elsif ($stream) {
		my $path = path_abs($root_dir, $stream);
		if ($path) {
			my ($filename, $basename) = $path =~ m!/(([^/]+?)\.[^./]+)$!;
			my ($ok, $error) = vlc_transcode($client, {
				type      => "file",
				name      => $filename,
				file      => $path,
				date      => POSIX::strftime("%Y-%m-%d %H:%M:%S %z", localtime),

				clientid  => "htmlview",
				good      => "HLS",
				set       => "HLS",

				keyframe  => "90",
				width     => "960",
				vb        => "1800",
				ab        => "128",
			});

			if ($ok) {
				for (my $i = 0; $i < 10; $i++) {
					my (undef, $segments) = encoding_status($basename);
					if ($segments > 2) {
						return $client->send_redirect(
							sprintf 'http://%s/?movie=%s', $request->header('Host'), $basename);
					}
					sleep(1);
				}

				return $client->send_redirect(
					sprintf 'http://%s/', $request->header('Host'));
			}
			else {
				$page .= sprintf q{
					<header>
						<h1><a href="/">iOS Streaming</a></h1>
						<span>%s</span>
					</header>
					<p>
						An error occured while transcoding:
						<em>%s</em>
					</p>
					<nav>
						<a class="i" href="/">&laquo; Overview</a>
					</nav>
				}, html_esc($basename),
				   html_esc($error);
			}
		}
		else
		{
			$page .= sprintf q{
				<header>
					<h1><a href="/">iOS Streaming</a></h1>
					<span>%s</span>
				</header>
				<p>
					Invalid path requested for transcoding
				</p>
				<nav>
					<a class="i" href="/">&laquo; Overview</a>
				</nav>
			}, html_esc($stream);
		}
	}
	elsif ($delete) {
		my ($ok, $error) = delete_cache($client, $delete);

		return $client->send_redirect(
			sprintf 'http://%s/', $request->header('Host'));
	}
	elsif ($json) {
		$page .= sprintf q{
			<script type="text/javascript">
				var old_pos = NaN;

				function startPlay() {
					var v = document.getElementsByTagName('video')[0];
					v.removeEventListener('canplaythrough', startPlay, false);

					if (isNaN(old_pos)) {
						v.currentTime = Math.max(v.duration - 10, 0);
					} else {
						v.currentTime = Math.min(v.duration, old_pos);
						old_pos = NaN;
					}

					v.play();
				}

				function toggleSeekable(btn) {
					var v = document.getElementsByTagName('video')[0];
					var s = /\?seekable=1$/.test(v.src);

					old_pos = v.currentTime;
					v.addEventListener('canplaythrough', startPlay, false);

					if (s) {
						btn.className = 'r';
						btn.nextElementSibling.style.display = 'none';
						v.src = v.src.replace(/\?seekable=1$/, '');
					} else {
						btn.className = 'g';
						btn.nextElementSibling.style.display = '';
						v.src += '?seekable=1';
					}
				}

				function fastForward(btn) {
					var v = document.getElementsByTagName('video')[0];
					v.load();
					v.addEventListener('canplaythrough', startPlay, false);
				}

				function updateStatus() {
					var v = document.getElementsByTagName('video')[0];
					var d = v.duration;
					var e = v.buffered.end(0);
					var p = parseInt((e / d) * 100);

					if (isNaN(e) || isNaN(d) || isNaN(p)) {
						document.getElementById('status').innerHTML = 'loading...';
					} else {
						document.getElementById('status').innerHTML = '' +
							''.substr.call(100 + e / 3600,       1, 2) + ':' +
							''.substr.call(100 + e %% 3600 / 60, 1, 2) + ':' +
							''.substr.call(100 + e %% 60,        1, 2) +
							((isFinite(d) && d > 0)
								? ' / ' +
								  ''.substr.call(100 + d / 3600,       1, 2) + ':' +
								  ''.substr.call(100 + d %% 3600 / 60, 1, 2) + ':' +
								  ''.substr.call(100 + d %% 60,        1, 2) +
								  ' (' + p + '%%)'
								: '');
					}
				}
			</script>
			<header>
				<h1><a href="/">iOS Streaming</a></h1>
				<span>%s</span>
			</header>
			<video controls autoplay src="/%s/stream.m3u8" width="100%%"></video>
			<br>
			<nav>
				<a class="i" href="/">&laquo; Overview</a>
				<span class="r" onclick="toggleSeekable(this)">Seekable</span>
				<span class="i" onclick="fastForward(this)" style="display:none">Jump to end</span>
				<span id="status">loading...</span>
			</nav>
			<script type="text/javascript">
				document.getElementsByTagName('video')[0].addEventListener('progress', updateStatus, false);
				document.getElementsByTagName('video')[0].addEventListener('canplaythrough', updateStatus, false);
			</script>
		}, html_esc($movie),
		   url_enc($movie);
	}
	else {
		$page .= q{
			<header>
				<h1>iOS Streaming</h1>
			</header>
			<ul>
		};

		foreach my $entry (@entries) {
			my $params = "$cache_dir/$entry/params.txt";
			next unless -f $params;

			my $info = json_read($params);
			next unless $info;

			my ($status, $segments) = encoding_status($entry);
			my $duration = $segments * ($info->{seglen} || 10);

			my $link = path_rel($root_dir, $info->{file});

			$page .= sprintf q{
				<li>
					<span class="t" style="background-image:url(/?thumbnail=%s)">&nbsp;</span>
					<a class="b" href="/?movie=%s">
						<strong>%s</strong><br>
						%s: %02d:%02d:%02d
					</a>
					<a class="r" href="/?delete=%s">Delete</a>
				</li>
			}, url_enc($link),
			   url_enc($entry),
			   html_esc($entry),
			   ($status eq 'complete') ? 'Ready' : 'Transcoding',
			   $duration / 3600, $duration % 3600 / 60, $duration % 60,
			   url_enc($info->{serverid} || '');
		}

		$page .= q{
			</ul>
			<nav>
				<a class="i" href="/?dir=/">Add movies &raquo;</a>
			</nav>
			<meta http-equiv="refresh" content="10">
		};
	}

	$page .= '</body></html>';

	my $response = HTTP::Response->new(200, "OK", [
		"Content-Type" => "text/html; charset=UTF-8",
		"ETag"         => $json ? $json->{serverid} : $etag
	], $page);

	return $client->send_response($response);
}


sub handle_client($)
{
	my ($client) = @_;

	while (my $request = $client->get_request) {
		if ($request->uri->path eq '/secure') {
			my $command = $request->uri->query_param('command');
			if ($command eq 'movies') {
				handle_movies($client, $request);
			}
			elsif ($command eq 'browse') {
				handle_browse($client, $request);
			}
			elsif ($command eq 'getpath')
			{
				handle_getpath($client, $request);
			}
			elsif ($command eq 'info')
			{
				handle_info($client, $request);
			}
			elsif ($command eq 'create2')
			{
				handle_create2($client, $request);
			}
			elsif ($command eq 'delete')
			{
				handle_delete($client, $request);
			}
		}
		elsif ($request->uri->path eq '/') {
			handle_index($client, $request);
		}
		else {
			handle_file($client, $request);
		}
	}
}


while (my $client = $daemon->accept) {
	while (waitpid(-1, WNOHANG) > 0) { }

	my $pid = fork;

	if (!defined $pid) {
		warn "Unable to fork: $!\n";
		next;
	}

	if ($pid == 0) {
		handle_client($client);
		exit;
	}

	$client->close;
}

