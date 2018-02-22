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
my $cache_dir = Cwd::realpath($ARGV[2] || '/tmp/.streamer_cache');
my $vlc_exe = "/usr/bin/vlc";

$SIG{'PIPE'} = 'IGNORE';

if (defined($ARGV[0]) && ($ARGV[0] eq '-h' || $ARGV[0] eq '--help')) {
	die "Usage: $0 [listen-port] [media-directory] [cache-directory]\n";
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
		my $sout;

		my $info = vlc_info($client, $file);
		if ($info->{'tracks-video'} && @{$info->{'tracks-video'}} > 0) {
			$sout =
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
		}
		else {
			$sout =
				'--sout=#transcode{' .
					'vcodec=none,acodec=aac,channels=2,' .
					"ab=$ab" .
				'}:std{' .
					'access=livehttp{' .
						"seglen=$seglen," .
						'splitanywhere=true,' .
						"index=\"$workdir/stream.m3u8\"," .
						'index-url=stream-###.ts' .
					'},' .
					'mux=ts,' .
					"dst=\"$workdir/stream-###.ts\"" .
				'}'
			;
		}

		my @cmd = ($vlc_exe,
			qw(--ignore-config -I dummy --no-sout-all),
			$file, 'vlc://quit', $sout,
			"--subsdec-encoding=$senc",
			qw(--sout-avcodec-strict=-2 -vvv --extraintf=logger --file-logging),
			"--logfile=$workdir/encode.log");

		warn "X: @cmd\n";

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

	my $info = vlc_info($client, $file) || {};
	(my $dur = $info->{duration} || '') =~ s![^0-9].*$!.0!;
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

	my $data;

	if ($snap) {
		if (open S, '<', $snap) {
			binmode S;
			local $/;
			$data = readline S;
			close S;
		}
	}
	else {
		warn "Unable to generate snapshot of '$file'\n";

		if ($info->{'tracks-video'} && @{$info->{'tracks-video'}} > 0) {
			$data = data_resource('video.png');
		}
		else {
			$data = data_resource('audio.png');
		}
	}

	if ($data && open C, '>', $cache) {
		binmode C;
		print C $data;
		close C;
	}

	return $data;
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
		return '';
	}

	if (length($path) < length($root) ||
		index($path, $root) != 0 ||
		substr($path, length($root), 1) ne '/') {
		return undef;
	}

	return substr($path, length($root) + 1);
}

sub path_abs($$)
{
	my ($root, $path) = @_;

	if (!defined($root) || !defined($path)) {
		return undef;
	}

	$path = Cwd::realpath("$root/$path");

	if (defined(path_rel($root, $path))) {
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

sub html_header()
{
	return q{
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
}

sub html_footer()
{
	return q{
			</body>
		</html>
	};
}

sub html_reply($$)
{
	my ($client, $body) = @_;
	return $client->send_response(HTTP::Response->new(200, "OK", [
		"Content-Type" => "text/html; charset=UTF-8"
	], html_header() . ($body || '') . html_footer()));
}

sub data_resource($)
{
	my ($name) = @_;
	my ($file, $type, $data);

	binmode DATA;

	my $offset = tell DATA;

	while (defined(my $line = readline DATA)) {
		chomp $line;

		if ($line =~ m!^name=(.+)$!) {
			$file = $1;
			$type = 'application/octet-stream';
			$data = '';
		}
		elsif ($file && $line =~ m!^type=(.+)$!) {
			$type = $1;
		}
		elsif ($file && $line =~ m!^[a-fA-F0-9]+$!) {
			$data .= pack 'H*', $line;
		}
		elsif ($file && $file eq $name && length($data)) {
			last;
		}
	}

	seek DATA, $offset, 0;

	if (defined($file) && $file eq $name && length($data)) {
		return wantarray ? ($data, $type) : $data;
	}

	return ();
}


sub handle_file($$$)
{
	my ($client, $request, $file) = @_;
	my $path = path_abs($cache_dir, $file);

	if (defined($path) && -f $path) {
		warn "F: $path\n";
		return $client->send_file_response($path);
	}

	warn sprintf "404: %s (%s)\n", $path || '?', $request->uri->path;
	return $client->send_error(404, 'No such file or directory');
}

sub handle_resource($$$)
{
	my ($client, $request, $file) = @_;
	my ($data, $type) = data_resource($file);

	if (defined($data) && defined($type)) {
		warn "D: $file\n";
		return $client->send_response(HTTP::Response->new(200, "OK", [
			"Content-Type" => $type,
		], $data));
	}

	warn sprintf "404: %s\n", $file;
	return $client->send_error(404, 'No such file or directory');
}

sub handle_seekable($$$)
{
	my ($client, $request, $movie) = @_;
	my $path = path_abs($cache_dir, "$movie/stream.m3u8");

	if (open F, '<', $path) {
		local $/;
		my $data = readline F;
		$data =~ s!^#EXT-X-PLAYLIST-TYPE:EVENT\b!#EXT-X-PLAYLIST-TYPE:VOD!;
		$data .= "\n#EXT-X-ENDLIST\n" unless $data =~ m!^#EXT-X-ENDLIST\b!;
		close F;

		warn "S: $path\n";
		return $client->send_response(HTTP::Response->new(200, "OK", [
			'Content-Type' => 'application/vnd.apple.mpegurl'
		], $data));
	}

	return $client->send_error(404, 'No such file or directory');
}

sub handle_browse($$$)
{
	my ($client, $request, $dir) = @_;

	my $path = path_abs($root_dir, $dir);
	my $up   = path_rel($root_dir, path_abs($root_dir, "$dir/.."));

	my $page = sprintf q{
		<header>
			<h1><a href="/">iOS Streaming</a></h1>
			<span>%s</span>
		</header>
	}, path_rel($root_dir, $path);

	if (opendir P, $path) {
		if (defined($up)) {
			$page .= sprintf q{
				<li>
					<a class="b" href="/browse/%s">../</a>
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
			elsif (-f $file && $entry =~ m!\.(mp4|mov|ogg|flv|wmv|avi|mkv|mp3|m4a|wma)$!i) {
				push @files, $entry;
			}
		}

		closedir P;

		foreach my $entry (sort @dirs) {
			$page .= sprintf q{
				<li>
					<a class="b" href="/browse/%s">%s/</a>
			        <em class="i">directory</em>
			    </li>
			}, url_enc(path_rel($root_dir, "$path/$entry")),
			   html_esc($entry);
		}

		foreach my $entry (sort @files) {
			my $file = path_rel($root_dir, "$path/$entry");

			$page .= sprintf q{
				<li>
					<span class="t" style="background-image:url(/thumbnail/%s)">&nbsp;</span>
			        <a class="b" href="/add/%s">%s</a>
			        <span class="i">%.02f MB</span>
			    </li>
			}, url_enc($file),
			   url_enc($file),
			   html_esc($entry),
			   (stat "$path/$entry")[7] / 1024 / 1024;
		}
	}

	$page .= q{
		</ul>
		<nav>
	};

	if (defined($up)) {
		$page .= sprintf q{
			<a class="i" href="/browse/%s">&laquo; Parent directory</a>
		}, url_enc($up);
	}

	$page .= q{
			<a class="r" href="/">Overview &raquo;</a>
		</nav>
	};

	return html_reply($client, $page);
}

sub handle_thumbnail($$$)
{
	my ($client, $request, $file) = @_;
	my $path = path_abs($root_dir, $file);
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

sub handle_add($$$)
{
	my ($client, $request, $file) = @_;
	my $path = path_abs($root_dir, $file);
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
						sprintf 'http://%s/movie/%s',
							$request->header('Host'),
							url_enc($basename));
				}
				sleep(1);
			}

			return $client->send_redirect(
				sprintf 'http://%s/', $request->header('Host'));
		}

		return html_reply($client, sprintf q{
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
		   html_esc($error));
	}

	return html_reply($client, sprintf q{
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
	}, html_esc($file));
}

sub handle_delete($$$)
{
	my ($client, $request, $movie) = @_;
	my ($ok, $error) = delete_cache($client, $movie);

	return $client->send_redirect(
		sprintf 'http://%s/', $request->header('Host'));
}

sub handle_movie($$$)
{
	my ($client, $request, $movie) = @_;
	my $file = path_abs($cache_dir, "$movie/params.txt");
	my $json = $file ? json_read($file) : undef;
	if ($json) {
		return html_reply($client, sprintf q{
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
					var s = v.src.indexOf('/seekable.m3u8') > 0;

					old_pos = v.currentTime;
					v.addEventListener('canplaythrough', startPlay, false);

					if (s) {
						btn.className = 'r';
						btn.nextElementSibling.style.display = 'none';
						v.src = decodeURIComponent('/%s/stream.m3u8');
					} else {
						btn.className = 'g';
						btn.nextElementSibling.style.display = '';
						v.src = decodeURIComponent('/%s/seekable.m3u8');
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
		}, url_enc($movie),
		   url_enc($movie),
		   html_esc($movie),
		   url_enc($movie));
	}

	return $client->send_redirect(
		sprintf 'http://%s/', $request->header('Host'));
}

sub handle_index($$)
{
	my ($client, $request) = @_;
	my ($etag, @entries) = cache_etag();


	my $page = q{
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
				<span class="t" style="background-image:url(/thumbnail/%s)">&nbsp;</span>
				<a class="b" href="/movie/%s">
					<strong>%s</strong><br>
					%s: %02d:%02d:%02d
				</a>
				<a class="r" href="/delete/%s">Delete</a>
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
			<a class="i" href="/browse/">Add movies &raquo;</a>
		</nav>
		<meta http-equiv="refresh" content="10">
	};

	return html_reply($client, $page);
}


sub handle_client($)
{
	my ($client) = @_;

	while (my $request = $client->get_request) {
		for (url_dec($request->uri->path)) {
			m!^/browse/(.*)$! &&
				return handle_browse($client, $request, $1 || '/');

			m!^/thumbnail/(.+)$! &&
				return handle_thumbnail($client, $request, $1);

			m!^/movie/(.+)$! &&
				return handle_movie($client, $request, $1);

			m!^/add/(.+)$! &&
				return handle_add($client, $request, $1);

			m!^/delete/(.+)$! &&
				return handle_delete($client, $request, $1);

			m!^/resource/(.+)$! &&
				return handle_resource($client, $request, $1);

			m!^/([^/]+)/seekable\.m3u8$! &&
				return handle_seekable($client, $request, $1);

			m!^/$! &&
				return handle_index($client, $request);

			return handle_file($client, $request, $_);
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


__DATA__
# Create file dumps using:
#   hexdump -v -e '36/1 "%02X" "\n"' /path/to/file

name=audio.png
type=image/png

89504E470D0A1A0A0000000D49484452000000300000003008060000005702F987000000
0473424954080808087C086488000000097048597300000DD700000DD70142289B780000
001974455874536F667477617265007777772E696E6B73636170652E6F72679BEE3C1A00
00086F4944415468DEED5AFD8F5C55197EDE73EEBD736777F66B76B7BB6DD9962DB440B7
5884DA468836342A262642D45490042480A89890F01FA03F138346A31112A3A6C1D84462
A221921843C0FA830405C4AEE573E976776776E76367E67E9C7BCE79FD61EFD4DB617742
37DB29249CE4E4DC3B1FEF799EF77DCEFB9E7B728999F1516E021FF1F63181CBDD9C0F1B
A07BBF77C5A8D66A064C33C2A19B04E126CB487EFD93C5C31F2A02C71F2A0E497667009A
910EDD28051FB2067BA597CBEF99BA269E9C9870874786FCFE828F93277FCF972D02C71F
DE5670ADDCCF6C6604891BA4834F1943D7F84E7E607AF7BEF8EA3D33CEF6ED57FA63C51D
182814E1BA3E5452F72255451457C06C41844B4FE0F8A35379D18AAE2316332471D073C4
616BF95ACF8AE268B1185CB3EFA073D5F401FF8AEDFB6962EC5A0C0FEE060037495A50BA
8158D511A91A6255834A5691242D1813434A1F20716909DC77DFB4EFE5D452BEDFC7E4F6
4939B573577EC7F6699A1CBF1A63C53DC8FB6303527890C283101E847010C55558D6D026
84D601946EC198109693B5CF6D84202A81C803E19247A0E67BB921EFDE7BEEC9B9320F29
7390C2839412CDF01C22558523F370A40F297310E4804880D92231011ACD39AC06EFA119
CCA3152E2088CA5049030030DCBF0FE8526DB74C42CC165A8768B4DE83EBF4C375FAE03A
7D70641F1CE94308074AB710C51544F10A82B88C202A238AABD8C8C1527800080CF48680
4AEA88E21544AA0AB085B109B48990E81612DD5A17289184E7F4C37507B0163D1F527820
21A17508ADF59AF14B4F801144CBA836DE58BF620A073977087EAE887C6E14BE5784EB16
20C845A35141B55EC652A982E595B3D1CA4A4DD52AABAEE35BFBC5DB8EF4B340AFD22843
08078ECCC3730AF0DC41E4BC21F8DE0804F5A3150468341A282FAC9AF2F2BB61A95442A5
B2E213D90A9178C358F3325B7A85AD99B542D45C4BA7C00CD18B3590EA01056F1F1A8D18
B596E2D5FA7254ADCF25B54A2D17AAC04AC1EFB2A5D78D362F81E8345B315BF30B6FFCE9
4767E275EAC7E49AFE094C3D90507B1D3CF3CC8BDA71C4296DF89F46E35521EC2C1B9A3D
F18BA5A5CDC51420EEA184AC85FCE58F173EBB75262D40C43DD98DB2ED5EF6379B1C4064
2F3901668665EE9AB337D32C33D8728F22C09CD69DADB5495D16F116133010BCC504AC01
77B1B9A504ACB5E02E7ABDF8AC4C60362042AF2260BBA6BCCD39C58009DC3309752BFB9B
5BC416C43D8A8065DBB5EC6F3A02E8490418662DDC76EB6C122C9B1E66216B4020BBD589
A19BCD2D27B0E585CCE85E4908D056436C290186650D00BDDB8D769BACDD1E7B8CC4ECC2
B62352F0ED4288AF59A6A22068C02A2652C494E449589204630CA817049819C6EAAE39FB
F80353453FA77F4AB4E34B63A3837CFDF59FE8BB76EF8DB238BC1BD668243A4492846886
CB582CBF86466B168936006D0181BB1EDE39254D728794E2D320DEC91013045B80106F9B
9CFF1A81D70AD906DEBAF33B9307FC1C3DB7FFBAE9D1CF1FBBD79D1C9B81102E92A48948
D5109A55247605896D816413C5E220144BC47505306D8EC0AD8F91B3F3DCF843D2138F38
8CA95D578E63FF7587FC91A149382E01641085C9CEF2F2FC2DA5CA69CD46ADEBADBB1F1C
BFC9759DE76FBEE540FE96C377D1F8F0F5605818AB9098102A5945182FA319CC23567504
5109AD68118045ADAA2CC0672E9AC0DDDF9AFCDC9437F1D4D058AE78ECD6DB0A7B761DC2
F0C055D03A409CD4A19206946E42F535303048343E09776EFE15609DAA499E7860EFBE61
FFE081A354AEBE0A47E691730791E81682B88C666B1EF5E6DBA835DF42A25BE971A240B3
91E0ADFF866118D10F2E8AC09D0F4EDEEEBA78FAC00D05FF0B9F791463C307606C0263A3
F4242D44A4AA68858B50490391AA60B5398744310868BEEF7C87706C60C8113BB7DD8CBF
FDEBFBA8AECE4290038645ACEA88552D2D580200011058381BE2F4EBAD96D5F6FEDF3D55
FE073D4594AE35DE900011D157BF397E75DEA7139F3C3CEC4F6C1B590BB30E2084038284
650DA59B68854B58A99F46189560AC0200941663CB8467690DC9F9F68D87261EFFF72B2B
3FCCFB8FF6E5FB814855DE9FCF49228A0D964B11DE79336AC6CACE4575FBED93BF29FF3D
4DF70C80698DC779224E1B789BBA437CB438E6F1D123DFC5D9D20B38573E857AF31DF8DE
080C2788E20A82A8745EAFED565A8CF9BD3955AB54F809006E16DC899F2FFDEACE07B65D
F1E2F30B8F14065C313CE2797E5E78420251686C1098A859D72608AD478C176A35F5E41F
7F5B7D36059D4B53B34947DB26C2CCEC64C04B005E1CB31F454CD5D53368B4E660AD4633
380721D68295E8E0BC4E0140C516674E07D1D2820A4AE7D4979FFB43750540FEFC66261D
9F7EB2F4C4D858DFCF0E1DCD1DCD79D16EC7A75D528AE138D0F34A61296CEAB32FBDB8FA
72A30195021F4841EBB427997B0BC050277800FD0086BE7EFFB693234567DFF4DE7C7E74
DC03D185E18E228BCAB2C2E2BC0AAB552D83963E71EACF8DC79796543D9DA40D7EBD2ED3
2E520588F49E3227293A03364EC1ABB4271912B66DD449433508A0D8DFEFEC3878A4EF8E
5DD3FE5784C4384932AE43566B2B8C6187407118DAB717CEAABFBEF99FE82FE5453587B5
C51B652AF17AE0C50720D0964916749C19934C3438EB951C80429B048011004521501C1A
75260B0372240C38A82DEBB2D6B60EA001A09EF62680563A81CD006EEFB7B2D732333A19
62D9FFE88CA7E38CE7DB84DE17816C14F2A9940A00FAD29E4FBFE7D45094F60040985EAB
B6572ED8D0FF7F1499B19388C8FC8E533B9DFAD71DF23100406BC716D4A94F375D136EDA
9DCC24669D45A533A1EF04DF292764242333A43A4F14B399C7745C739A4999DA758188A8
6332D1E1B5AC87CEA7B38C6EB181F7BB11EA940E75D8C9CED31E395B0768BD47D80C99F5
805C00942FE2197803BBB4C13CBCC178C19C74B95EF6E820F341B6EBEB02A58FDF56B9CC
ED7F84AF9D04F22A1E080000000049454E44AE426082

name=video.png
type=image/png

89504E470D0A1A0A0000000D49484452000000300000003008060000005702F987000000
0473424954080808087C086488000000097048597300000DD700000DD70142289B780000
001974455874536F667477617265007777772E696E6B73636170652E6F72679BEE3C1A00
0011B64944415468DED55A097054759AFFDED957D29D4ED2E95C24310728102190C8A5E8
082B22B888948E6EE9B8B34AD5EE8CAE78A0966E39B3BB2385C3ECACEB4C79CC8E6E8DB3
E28C8E0E223028E231C891102487841C84DC571FE9A4EFEED7EFBDFDFD5F9A4B995598D9
AAA5AB3EDECBEBF7FEFFEFFC7DBFEF359CAEEB74297FC4BFC422CF3DF7CF5971455C46C4
9570A4E7E308D1F3751CB9A9F36C5C1BD7491FC5F7A33887E8A3FAD4B1DF2CA5F66ED8F0
83898BD99BBBD8086C7A6E5381A070B74081B592242D76E7B9065C79F9366756B6CD6635
5B24C92443613EA9C4B9544AD3934A428FC7E30AE934CEF382A2A4140A8682719FC71BF3
F9FD15A4EB07A1CEEF5549DFF6E4862747FECF0CD8BC65D3DFF144F7C926CBACD933677A
4B4B4B0AEC76A795E7390A4C4CD024646232609C8F8FFB291A8D522A9522B3D94475750B
88DD67329948964DA4A91A656666E23B8B1E0E85223E9FD7F7455B5BAEDFE769D5887EF9
C4C6275FFD8B19B065CB16A444F295E2E29219F36A6A33E0F53C41E039ABD546F5F507A9
ADBD0DCEA516FCF31A56EDD739BE5F17F5FEAAA22A4F4F4FD7F57687E383258B97504A4B
91CD9641EFBFBF5B8F46237B88F8B90859DEC2058B687AD50C186427AFD7DBBFEBFD1D93
9ED191018EE47B376EDC38FA6719B079CB33EBAC16DB8B4BAFBEC66CB73B324551A44020
404EA793AC562BBCCAD3E0D0201D6DFA9C1A1A0E7FBE63FBAEEEE1E1E122AC9D0FC985D8
DFFADD9B545E514616B385F6EDDB4F8D8D0DDB5E7EE9976BD9FACF3EFBAFB388E31FE478
FEEEB9736BCCF3E7D5111CA48F8C0E9FD8F3E1FB8E7038FCBD27363EF5F64519B0F9C79B
7E545E51BE7E41DDC25C3595E2239108357E7E983C1E4FBF2008453535F3848AF20AE238
3252A5BDA383FEB07B0F1DEF3C49A22490AEE974F5E285B46EED6A62214AA574BAFB9EEF
527757274A22EEC5638F6DDAB4E98F2AAF96F2BA5E8B2D9FCAC8C870DF7ACB3A3C2F91AA
A6927B3EFCD0333434F8AB271E7BF29F2EC880679F7DE6EAECDCDC77D7DC7C4BD6D8D828
AF63B7F777EF0E68A4DE1F8F28BF412E9725B5C4A3EF6D7B6F7D5DDD55E2ED77DC46CE2C
07C5E2318AC512E4F5F9C962B150D9B41218A8E3DC4A1F7DB28F5E7B7D2B49A244F14482
46FAFBE8FAEBAFA35B6FBD0511CDA60C9B8D649399B2B00E9487A8080E97DCB9737B7032
105CFBF8E34F7DF6CD6194E71E5D79E32A29140AF2B22C53734B3341F97F7CFCD127B7B2
AF67CF9E3D383E3E2E5AAC56BEFD440F3DB2F1299A79C5747AE8C1EFC3D30A5D56566228
1A0A07C90A4358EAADB9F926BA66C96202BC529E3B8FB21C59A4699AA16C0ACAC650F4E1
4818293A4E6C4F20198CE7E46BAF5D16DBBE7DDBA3D8F6020C206E514E764E466FDF4923
77554DA594925AFEC8C60D7F1F0C8566CCA9A9CE6E3EDAC2AFB8691539B3B32927C749C5
4585462AC99289944492789DA7E6A3CD545B576BA484C00B34ADB898FA0707E9507D0352
D14743C343B467F76EBAACBC9864B359CF72387C0E8763B0645A69CDA2C58B10CD186564
64BA993E17DCC8504C9C192105E2D0A2854BA8AA72FA3D4698CD6612714D83510A14661E
4F2615C0660CD738CA766691A2240DB8BC69D54D24C19B264936FE6645BFF9C7FF464D2D
2DC67936C0E0934F3EA6C2B2BFA55424E98F47BDDEDEDEBEDCC2A262238552888EC814B8
F04EAC1F048EDF88DC34259309164A32C37B0CE3474646C83F3E4E1FEFDD4BAE3C17EDAF
6FA4E1E151231DD8E7910D0F205516190A9A10BDC1C1610A872374F98C2ACA73E5D12B2F
BF40C7DA8ED3AFB7FE06E8D5643CD3D6D6811AB0E6B24F51617EEACAD957B266876B1914
8F2726983E176680A6FFE4BD1DDBAEBDF38EBB4CA1D02472394409A4C50FFEE519EAEEE9
211E79DC78703FAD425EB3EB4025C300A6F4BC39738C23EA83FE7BEB6FE9AD77DE35CE13
F128DDB6762DAD59BD8A2A2B2BE8E9A71E8733C6E8C517AAA87F6424DE7DB2CF24CB12F7
E003FF208AB2803D44CACD76D13BDBDE16983E178442F0B8F0F0C60DAD37DE70E3F4EBBF
B55C88A0B846C6865068093A72A4911A8F7C1E78E985979CF7AEFF2E8D8E4728E019220E
457BD71D77D2EAD52B0D03FCDE71FAF65DDF41FECB30C00244E129118B1986AEBCF106BA
7DDD3AD44421B1088710A1EEEE6EAAB8AC9C12A938B9725C2CF769EFDE3DEA6707F677FE
74CB73D5D0573D5B47E1873FFCE19F34E0E0C17D8B44595EEFC8725A1B0ED77315159554
58508C8D2651B40EAAADADB36464D88C3AB0565C4792D5496A688C1E7978031047205022
DAFCEC661A1EEAA7782444E33E2F8D0E0CC2A8314A26E274BCBD83B66FDF01C7EA5433F7
4AA449140A6720E54C54515685940BD3D6375EA786C6A3E4F38E098505EE7D77DF7DCFC0
374A21E6FD95AB562C9B56342DAA286A76776F1F3DFFF3FFA0F9F3E62756AE58294B92CC
05027EFAFEFDDF03DA22BA08760AC5AB297F834295484624C6C6BC048A436EB79BA11738
8F998A80526E773E102B07E7455455859AC8CB3322E2CE2B243BB811EB0FEFED7C97F61F
3840478E1E2320129F69954382242D875EF56747E17FAB01113716216F3906004CA90842
BC6BF707A6E6E626405E05CD9B3B974A4BCBC86177C07B71038D38CE018378A31ECACBB3
E8D7AFBD6644887570D6071810A85056D7354369D62798612178BBFB4417BC7D98FA7A7B
F4EEDE7EBDBDA39B67F72781668AC39E099D8A59D640D4AFAD013C68BA7AE9A2FBE6CFAF
7D7AD9F2BFCA6348C1E802BE61884031A400C3350D10978F86540DC42843EE3AB39C9499
61076C4A0CFA0C8599B07DD27D04CFC72804832680660303BDD4D9D9C1A8090527831489
46503B82C15801E18691A1489406064774FF7820C9C68FA686FA27BE4904B463ADED9FBA
0079D17038545559993980E6C330F9E34F3F6390A8A151752BC9A47F32E09B565E5E963F
73D62CC10E47715040365B49E052A00F19686A028A344949F84D49A9948C4E524C335332
A55132384211A9109C492311F523DADD24A909D2180D67A988FE91E374D0B4A2020E8E33
1D3CDCF440CD550B4D471B0E3DF47511600E765657CFBAAF665ECDD36B6E59CBD9326C96
DEDE1EC200429F1D6880F78646A2A1D0D6C1BE9EB71445598414790CC893E32E2890B3C0
6BB2EC36830B69A8115293A4997288976D24448728692B251E1112432749CA9F63A09438
D14E622198289A9DE86B22D15D8D3C8E93181B35BAB80460E005913EFAF440047CEBF696
C38777FDC908C0300D46845A5B8FBD1389C578E4E843757575F1A54B97DA41EC04972B97
D18082A3CDAD8FD8B3B2EED534BD4D27EDA3643CB13227DB9EDDD5DE496D069F3151B641
3320B91A65480952714D4FF88893C18FA01037E5304318F4B223CB57CEE2C43D26E2E218
070A1793121D2353B49FAE985E616D39D67E3F1EDBF5755442810C9D3C7172DBF0E0F020
6680F5DD5D276A96DF7043B4664E4D2EF8103FF38ACBC9E3F564F97CE38B2727438B1929
2B2999A200C3C363F4C19EBD98D226C31EBF3F393C3A9609BA21A1DB1A939823CB6E500E
5BAC8F040D2907CAC2A782C44B59C6E476CA28C320A42565149232D94DEEC2524E6D39B6
E26B3B31A2A0E3E1184E7B8032E14F3EFAB4CF3BDBB37A6864E8E63C97CB5E565E1E9B79
C52CBEE6CA1A1B665E31180AA323278C226585CED0E59EEFDC09048A65C4123132C966D4
838889CB4763A31E83C4F5F4A231C64F804A67E90E070C8A44B99C6CA7D1C038789BD31D
2420BDD4333AD1B8626231E32F68A48421CC582B241752868633A3B2AA7CA1CB9D570332
5685629F70E7B9F5AC6CA7C99E6997AC560B8759176246F3E5854432C1C722312E180C26
278393F15030940C8783EAC4E4A480083AD133462683E109782C132050246008C8763A52
2E578E352F378773BA0A48B11490E63B4EEDA309EA3BD640CD68AE1734D473462C8DA8D9
5881437220D950D20D63EA305E16984C66A72C8B764932D9251C4551CA9424D1AA28A928
186B4849A6828A92082695D424A215407F18EBEE3A7914111E63E90AF1404257CC9D9B2F
89622D9AE412786085C0F3859515A566ACC3F7811832383E5A7F90BBA8D72A6943584391
19E34E1F2D10475AAC6943F92FC9A9BA8A40C26961E789B4B0744D3200397BBFEA850BDD
5C4A5B0FD47A4016C5BCEA9933E8686B1B7D7EE80077512FB6F429AB536939651053702C
6D906074BC3342671DB5742765CFAAD5D5D5564D9633F1B04BE038BB4A82634EDD423B5A
1F1CC1CFC6AAAB254EC8B7399D8AC8F3990E9B0943117F9AB69F63C09C050B2EC3E0BB0E
3C600D26B9424ED772D1F633CFDAFCBC9F2B6BAFBAE8B77A288FA4C8098A200AAA6432EB
AC6FA08604104811CD50D678894FA1094E8C7BCCA3033D641139622FC54E658E785A718E
7F5516E5ABC0F88402B7DB940198B362F2B26298401E9320CA10D1383FFB6F01E79AAA53
029BC4412F1231463392E0FD71E3EFB8814AE8AC9A6E70A03347CCC1EC5CD5E4582C2A1B
131EA0D3E57291CCAB94975F44A18097228A4EFD9D5F906CB323AE221AA1C9983D4E3B20
1DD4F6DA39D5D75CB7E42AEBB4C27C536747BB31BCEC7C6F07F583FEFEEAD55768706898
5EFDC54B348CE1E3172FFC0C7381975E7CFEA73406BEFFE2F33FA151AF9FFEEBE59FD308
66DCDFBEF69F348CEFDF7DEB751A065CEED9F1B671FFC77FF83DEEF7D31F3FD84E5E7F80
0E7EB48BC60313D4D6544F13C1100DF7760052E3149C1807C506FE0B12992C99E42EA922
6BA693EC4E17F2973368493A8DA760744EDD02FDCEDBFE9A76EDDC8DF110D41781292C9F
4911FF00E596CF476BB7008B99E7E175015D34D843B26BA6E111160596612A52323CD844
E6FC5953736C8A7958A1543245C70EEEA4CAF9CB0D56CABE53C15A351CBB5B0F50F18C79
C61B09E335A355269BD50C1EE4A7E29272B05A9DFC13411AEEEB82D7150A8E8FA1D1A19F
883A9DEC1F1A6B6A38947F4E0DE4174F23477E154916C626CDA446BC249A6CC4A1917002
0406C092A94296D8708EC7C167D0EED028A7CA4404D78136C48B29E42ABEE794A9C9090E
2095373CA80BC63BAEF49B1B1E97B006AF4D951A1CAA19745B37A6379E756262EBF3AC60
8C148C224AB8B1FB2B459CE9AEC4C6269AE2CD67C083D3E90CA070A7AF1AA77A9ABF8039
4D5D679B32EACC4D711AF6F7D4FDB88E5CD54ED183D30B71C61A0C3835F61648D70DE30C
030C4AC41BB4E29421B178C458075FB77CC900FDCBD3F2B97F9EBA8B3BF7090E1BEBFC99
EB1CE3305A7A359D3BE306EECB2B9D179E8DF192BD8ED40C034E7121DE785EC3DC9C8845
302FAB6174B0FDE718F0957EA69FBB91E11518C5EB674CE5D230C09D653FDB9CADC5A59D
A07F657DFDBC0EE3B82903D8654D9FF200F3BCCEEA4689D3C4D80885267DEC461D75E499
5E56F6C657C99C7E4AF4F36CA44F05E52C8DD8296F784D3BED6256A84693D1A7F2584F37
1C9DA50F7B825DD3353ADB1E2E7D4D01E42630EE268180A1A09FA2FE08C5529CF142C064
B132D8D562B1444010B89BDF7CF34DF52B06300F33E168EA783AAC508A63736D2840365B
268E4172E660241CF712A617F20CF5931303F9C8603F15D9DC74B2E30BCA2D2CA59EF626
CA2928C5F7BD64EB384AFD5DAD5450329D7ABB9AA9A07406787A1BC041A09E638D545459
4DFE810E9A5D7B0DC84410F34FBE318D4DFABDD8C71FF17A860455D776689CFE70F3A1FA
81F38C94E9DC400A04BC8364B598E8786B2BCD060F3F7CF0002D5DB602C7FDC6B1A9B19E
963AB2E9F8A17D74CDB295D4D7FA19D96B1791CF33420E2726B6C14EA31905B18E808260
CD2EE41FC1FA2A45E159B3C942C95898B2F38A00B371CA2B2E234D89506EC1340A78FA55
34DB7853C3A7EAC4845F4A2692C701093FD3A2B6DF7DF1C5C7E1F3BED8627DE0DBEB56D3
F101581EF6D3898E6374F9AC5906F666E7BA8094EC6D0244E0D3E8C1D3549CC8283625DD
85E3B118EBC01AE6018CCB0935955454B47D40BEA2B3548220E398E8028E22EA05AC990F
A1503D586E080CE92494ED46F487759D1F82EF8E371F3A34F88D7FA59C186C3720B1A4EC
32F2F9FC2AF879A8A3B32BC3C82E9E4F00CA624004085823CF45389D0B63B310923B88F0
06B5542A00E542B03602CB22500A4C93C7518DA00700FFD4303688505CC4F558A4B5A525
AAFF99BFF39E6380886969CC17C008EC8920F9DF405DEDB2CAFCBE03070EC4FEDFFF4EDC
D9D94D3D032351E4C5BF4702FE1F757575252EA91FBA9B8EB58755D2BFD5DA50DF7829FE
521FD353FA4DAD472E2DE54F1BA011B7A6F50830F112FC7097FA7FF6E0E912FF5CF206FC
0F73C7E9D5B74696A40000000049454E44AE426082
