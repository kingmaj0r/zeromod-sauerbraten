#!/usr/bin/env perl
use strict;
use warnings;
use bytes;
use Socket qw(getaddrinfo SOCK_STREAM);
use POSIX qw(EINTR);


# settable vars
# irc server
my $server = 'irc.andrius4669.org';
# irc server port
my $serverport = 6667;
# autojoin channels
my @channels = ('#test654');
# nicks which shall be ignored
my %ignored_nicks = ();
# nick for our bot
my $ircnick = 'tester';
# username for our bot
my $ircuser = 'tester';
# realname for our bot
my $ircreal = '-';
# irc password
my $ircpass = '';
# message use on quit
my $irc_quit_message = '';
# irc command characters
my @irccmdchars = ();
# talkbot number. -1 = don't use talkbot
my $usetalkbot = -1;
# talkbot per-channel overrides. channel names must be lowerchar
my %talkbotchans = ();
# whether to show join/part/quit/kick/nick (irc channel consistency) messages
my $showjoinpart = 1;
# $showjoinpart per channel override
my %joinpartchans = ();
# show sauer ips? this is overriden by geoip message by server anyway. only relevant if server don't give geoip info to bot
my $showsauerips = 1;

warn "ohayo!\n";

$| = 1; # autoflush

my $s; # irc socket

my $quitting = 0;

my $inbuf;
my $registered;
my $autojoined;
my %joinedchans;
my $myircnick;

sub sauer_use_talkbot {
	my $chan = lc $_[0];
	return $talkbotchans{$chan} if defined $talkbotchans{$chan};
	return $usetalkbot;
}

sub sauer_show_joinpart {
	my $chan = lc $_[0];
	return $joinpartchans{$chan} if defined $joinpartchans{$chan};
	return $showjoinpart;
}

sub irc_reset {
	$inbuf = '';
	$registered = 0;
	$autojoined = 0;
	%joinedchans = ();
	$myircnick = $ircnick;
}

sub irc_connect {
	my ($_ircserv, $_ircport) = @_;
	my ($err, @res) = getaddrinfo($_ircserv, $_ircport, undef);
	return undef if $err;

	my $s = undef;
	for my $a (@res) {
		return undef if $quitting;
		socket(my $c, $a->{family}, SOCK_STREAM, 0) or next;
		connect($c, $a->{addr}) or next;
		$s = $c;
		last;
	}
	return $s;
}

sub irc_send {
	return undef if $quitting;
	my ($len, $sent) = (length($_[0]), 0);
	while($sent < $len) {
		my $slen = send($s, substr($_[0], $sent, $len-$sent), 0);
		return undef if !defined($slen) or ($slen < 0);
		$sent += $slen;
	}
	return $len;
}

sub is_irc_command {
	my $chr = $_[0];
	for (@irccmdchars) {
		return $chr if $chr eq $_;
	}
	return undef;
}

sub irc_unrecognised_command {
	my ($nick, $msg) = @_;
	irc_send("NOTICE $nick :unrecognised command: $msg\r\n");
}

sub do_ircuser_command {
	my ($chan, $nick, $msg) = @_;
	my $unknowncmd;
	# command without args
	if($msg =~ /^([A-Za-z][A-Za-z0-9]+)$/) {
		my $cmd = lc $1;
		# todo: parse
		$unknowncmd = 1;
	}
	# with args
	elsif($msg =~ /^([A-Za-z][A-Za-z0-9]+) (.+)$/) {
		my ($cmd, $args) = (lc($1), $2);
		# todo: parse
		$unknowncmd = 1;
	}
	else {
		$unknowncmd = 1;
	}
	if($unknowncmd && !defined($chan)) {
		irc_unrecognised_command($nick, $msg);
	}
}

sub notify_irc_join; # someome joined
sub notify_irc_part; # someone parted
sub notify_irc_quit; # someone quit
sub notify_irc_kick; # someone got kicked
sub notify_irc_nick; # someone changed nick
sub notify_irc_chat; # someone said something
sub trigger_irc_namereply; # we got list of nicks in channel
sub trigger_irc_part;      # we got parted off from channel
sub trigger_irc_kick;      # we got kicked off from channel
sub trigger_irc_quit;      # we got disconnected from irc network

sub handle_term {
	if(defined($s)) {
		irc_send("QUIT :$irc_quit_message\r\n") if $registered;
		shutdown $s, 1;
	}
	$quitting = 1;
}
$SIG{HUP} = "IGNORE";
$SIG{TERM} = \&handle_term;
$SIG{INT} = \&handle_term;

sub irc_joinchan {
	return unless @_ > 0;
	irc_send "JOIN " . join(',', @_) . "\r\n";
}

sub do_irc_command {
	my ($cmd_nick, $cmd_host, $cmd_user, $cmd, @cmd_args) = @_;
	$cmd = uc $cmd;
	if($cmd =~ /^[0-9][0-9][0-9]$/) {
		my $mynick = shift @cmd_args;
		# RPL_WELCOME RPL_YOURHOST RPL_CREATED RPL_MYINFO
		if($cmd eq '001' or $cmd eq '002' or $cmd eq '003' or $cmd eq '004') {
			# use these messages to mark successful nick registration
			$registered = 1;
		}
		# RPL_NAMREPLY
		elsif($cmd eq '353') {
			my $chan = lc $cmd_args[1];
			if(defined $joinedchans{$chan}) {
				for my $n (split(' ', $cmd_args[2])) {
					my $privchr = substr($n, 0, 1);
					if($privchr !~ /[A-Za-z\[\]\\`_\^\{\|\}]/) {
						$n = substr($n, 1);
					} else {
						$privchr = '';
					}
					$joinedchans{$chan}->{$n} = $privchr;
				}
				trigger_irc_namereply $chan;
			}
		}
	}
	elsif($cmd eq 'PING') {
		if(@cmd_args == 0) {
			irc_send "PONG\r\n";
		}
		elsif(@cmd_args == 1) {
			if(index($cmd_args[0], ' ') >= 0) {
				irc_send "PONG :$cmd_args[0]\r\n";
			}
			else {
				irc_send "PONG $cmd_args[0]\r\n";
			}
		}
		elsif(@cmd_args == 2) {
			if(index($cmd_args[1], ' ') >= 0) {
				irc_send "PONG $cmd_args[0] :$cmd_args[1]\r\n";
			}
			else {
				irc_send "PONG $cmd_args[0] $cmd_args[1]\r\n";
			}
		}
	}
	elsif($cmd eq 'JOIN') {
		my @chs = split(',', $cmd_args[0]);
		for my $ch (@chs) {
			if(length($ch) > 0) {
				# channel names case insensitive. keep this in mind when addressing hashset
				my $chan = lc $ch;
				if($cmd_nick ne $myircnick) {
					if(defined($joinedchans{$chan}) && !exists($joinedchans{$chan}->{$cmd_nick})) {
						$joinedchans{$chan}->{$cmd_nick} = '';
						notify_irc_join $ch, $cmd_nick if !exists $ignored_nicks{$cmd_nick};
					}
				}
				else {
					# maybe TODO: add some sort of protection to refuse joins we did not initiated
					$joinedchans{$chan} = {} unless defined $joinedchans{$chan};
				}
			}
		}
	}
	elsif($cmd eq 'PART') {
		my @chs = split(',', $cmd_args[0]);
		for my $ch (@chs) {
			if(length($ch) > 0) {
				my $chan = lc $ch;
				if($cmd_nick ne $myircnick) {
					if(defined $joinedchans{$chan} and exists $joinedchans{$chan}->{$cmd_nick}) {
						notify_irc_part $ch, $cmd_nick, $cmd_args[1] if !exists $ignored_nicks{$cmd_nick};
						delete $joinedchans{$chan}->{$cmd_nick};
					}
				}
				else {
					if(exists $joinedchans{$chan}) {
						trigger_irc_part $chan;
						delete $joinedchans{$chan};
					}
				}
			}
		}
	}
	elsif($cmd eq 'QUIT') {
		if($cmd_nick ne $myircnick) {
			notify_irc_quit $cmd_nick, $cmd_args[0] if !exists $ignored_nicks{$cmd_nick};
			foreach my $chan (keys %joinedchans) {
				if(exists($joinedchans{$chan}->{$cmd_nick})) {
					delete $joinedchans{$chan}->{$cmd_nick};
				}
			}
		}
		else {
			trigger_irc_quit;
			%joinedchans = ();
		}
	}
	elsif($cmd eq 'KICK') {
		my @chs = split(',', $cmd_args[0]);
		for my $ch (@chs) {
			if(length($ch) > 0) {
				my $chan = lc $ch;
				my @nicks = split(',', $cmd_args[1]);
				for my $nick (@nicks) {
					if(length($nick) > 0) {
						if($nick ne $myircnick) {
							if(defined($joinedchans{$chan}) and exists($joinedchans{$chan}->{$nick})) {
								notify_irc_kick $cmd_nick, $ch, $nick, $cmd_args[2] if !exists $ignored_nicks{$nick};
								delete $joinedchans{$chan}->{$nick};
							}
						}
						else {
							if(exists($joinedchans{$chan})) {
								trigger_irc_kick $chan;
								delete $joinedchans{$chan};
							}
						}
					}
				}
			}
		}
	}
	elsif($cmd eq 'NICK') {
		my $newnick = $cmd_args[0];
		# iterate thru all channels and rename
		for my $chan (keys %joinedchans) {
			if(exists($joinedchans{$chan}->{$cmd_nick})) {
				$joinedchans{$chan}->{$newnick} = $joinedchans{$chan}->{$cmd_nick};
				delete $joinedchans{$chan}->{$cmd_nick};
			}
		}
		if($cmd_nick ne $myircnick) {
			notify_irc_nick $cmd_nick, $newnick if !exists($ignored_nicks{$cmd_nick}) or !exists($ignored_nicks{$newnick});
		}
		else {
			# rename myself if I am being renamed
			$myircnick = $newnick;
		}
	}
	elsif($cmd eq 'MODE') {
		# dunno how exactly parse modelist (which modes takes params, which dont?)
		# so just send NAMES to ensure consistency if it's channel mode
		# may be slow/laggy on huge channels. TODO: parse MODE list
		my $chr = substr($cmd_args[0], 0, 1);
		# it's channel mode?
		if($chr eq '#' or $chr eq '&' or $chr eq '!' or $chr eq '+') {
			irc_send "NAMES $cmd_args[0]\r\n";
		}
	}
	elsif($cmd eq 'PRIVMSG') {
		if(defined($cmd_nick) and !exists($ignored_nicks{$cmd_nick})) {
			my $chr = substr($cmd_args[0], 0, 1);
			# it's channel message
			if($chr eq '#' or $chr eq '!' or $chr eq '+' or $chr eq '&') {
				my $chan = lc $cmd_args[0];
				if(defined($joinedchans{$chan}) and ($cmd_nick ne $myircnick)) {
					my $ch = substr($cmd_args[1], 0, 1);
					if(is_irc_command $ch) {
						do_ircuser_command $cmd_args[0], $cmd_nick, substr($cmd_args[1], 1);
					}
					else {
						notify_irc_chat $cmd_args[0], $cmd_nick, $cmd_args[1];
					}
				}
			}
			# it's private message for me
			elsif(($cmd_nick ne $myircnick) and ($cmd_args[0] eq $myircnick)) {
				my $ch = substr($cmd_args[1], 0, 1);
				if(is_irc_command $ch) {
					# channel, nick, command
					do_ircuser_command undef, $cmd_nick, substr($cmd_args[1], 1);
				}
				else {
					do_ircuser_command undef, $cmd_nick, $cmd_args[1];
				}
			}
		}
	}
#	elsif($cmd eq 'NOTICE') {
#		if(defined($cmd_nick) and !exists($ignored_nicks{$cmd_nick})) {
#			# only watch chans I'm in, and filter out crap
#			my $chr = substr($cmd_args[0], 0, 1);
#			# if it's chan
#			if($chr eq '#' or $chr eq '!' or $chr eq '+' or $chr eq '&') {
#				my $chan = lc $cmd_args[0];
#				if(defined($joinedchans{$chan}) and ($cmd_nick ne $myircnick)) {
#					notify_irc_chat $cmd_args[0], $cmd_nick, $cmd_args[1];
#				}
#			}
#		}
#	}
	elsif($cmd eq 'ERROR') {
		trigger_irc_quit;
		%joinedchans = ();
	}
#	print '>';
#	print "[nick=$cmd_nick]" if defined $cmd_nick;
#	print "[host=$cmd_host]" if defined $cmd_host;
#	print "[user=$cmd_user]" if defined $cmd_user;
#	print "cmd:[$cmd]" if defined $cmd;
#	print "args:";
#	for(@cmd_args) { print "[$_]"; }
#	print "\n";
}

sub process_irc_input {
	my $line = $_[0];
	my $cmd_nick; # nickname in case it's user, empty in case server
	my $cmd_host; # hostname in case it's user, server name in case server
	my $cmd_user; # username in case it's user
	# parse prefix if it exists
	if(substr($line, 0, 1) eq ':') {
		my $idx = index($line, ' ', 1);
		my $prefix;
		$prefix = substr($line, 1, $idx-1) if $idx > 1;
		if($idx > 0) {
			my $ll = length($line);
			do { $idx++; } while($idx < $ll and substr($line, $idx, 1) eq ' '); # skip spaces
			$line = substr($line, $idx);
		}
		return if $idx <= 0;
		if(defined($prefix)) {
			if(($idx = index($prefix, '@')) > 0) {
				$cmd_host = substr($prefix, $idx+1);
				$prefix = substr($prefix, 0, $idx);
			}
			if(($idx = index($prefix, '!')) > 0) {
				$cmd_user = substr($prefix, $idx+1);
				$prefix = substr($prefix, 0, $idx);
			}
			if(($idx = index($prefix, '.')) >= 0) {
				# it's server
				undef $cmd_user;
				undef $cmd_nick;
				$cmd_host = $prefix;
			} else {
				# it's user
				$cmd_nick = $prefix;
			}
		}
	}
	# parse rest of command into list
	my @irc_args = ();
	my $start = 0;
	my $len = length($line);
	while($start < $len) {
		if(substr($line, $start, 1) ne ':') {
			# it's normal argument
			my $idx = index($line, ' ', $start);
			if($idx >= 0) {
				push @irc_args, substr($line, $start, $idx-$start);
				# skip spaces
				do { $idx++; } while($idx < $len and substr($line, $idx, 1) eq ' ');
				$start = $idx;
			} else {
				push @irc_args, substr($line, $start);
				$start = $len;
			}
		} else {
			push @irc_args, substr($line, $start+1);
			$start = $len;
		}
	}
	do_irc_command $cmd_nick, $cmd_host, $cmd_user, @irc_args;
}

sub sauer_esc_str {
	my $str = $_[0];
	$str =~ s/\^/\^\^/g;
	$str =~ s/"/^"/g;
	$str =~ s/\f/^f/g;
	$str =~ s/\t/^t/g;
	$str =~ s/\n/^n/g;
	return '"' . $str . '"';
}

sub sauer_wall {
	my $str = sauer_esc_str $_[0];
	print "s_wall $str\n";
}

sub add_sauer_talkbot {
	my $nick = sauer_esc_str $_[0];
	print "_tbts = (listtalkbots $nick); if (<= (strlen \$_tbts) 0) [talkbot -1 $nick] [];\n";
}

sub del_sauer_talkbot {
	my $nick = sauer_esc_str $_[0];
	print "looplist _tb (listtalkbots $nick) [cleartalkbots \$_tb];\n";
}

sub ren_sauer_talkbot {
	my ($onick, $nnick) = (sauer_esc_str($_[0]), sauer_esc_str($_[1]));
	print "looplist _tb (listtalkbots $onick) [talkbot \$_tb $nnick];\n";
}

sub say_sauer_talkbot {
	my ($nick, $msg) = (sauer_esc_str($_[0]), sauer_esc_str($_[1]));
	print "_tbts = (listtalkbots $nick); if (> (strlen \$_tbts) 0) [s_talkbot_say (at \$_tbts 0) $msg] [];\n"
}

sub notify_irc_join {
	my ($channel, $nick) = @_;
	if(sauer_use_talkbot($channel) > 9000) {
		add_sauer_talkbot $nick;
	}
	elsif(sauer_show_joinpart $channel) {
		my $msg = "\f5[irc] \f0join: \f7$nick";
		$msg .= " \f4$channel" if (keys %joinedchans) > 1;
		sauer_wall $msg;
	}
}

sub notify_irc_part {
	my ($channel, $nick, $reason) = @_;
	if(sauer_use_talkbot($channel) > 9000) {
		del_sauer_talkbot $nick;
	}
	elsif(sauer_show_joinpart $channel) {
		my $msg = "\f5[irc] \f4part: \f7$nick";
		$msg .= " \f4$channel" if (keys %joinedchans) > 1;
		$msg .= " \f7(\f2$reason\f7)" if defined($reason) and (length($reason) > 0);
		sauer_wall $msg;
	}
}

sub notify_irc_quit {
	my ($nick, $reason) = @_;
	my $shouldshow = 0;
	foreach my $chan (keys %joinedchans) {
		if(exists $joinedchans{$chan}->{$nick}) {
			if(sauer_use_talkbot($chan) > 9000) {
				del_sauer_talkbot $nick;
				return;
			}
			if(sauer_show_joinpart $chan) {
				$shouldshow = 1;
			}
		}
	}
	if($shouldshow) {
		my $msg = "\f5[irc] \f4quit: \f7$nick";
		$msg .= " (\f2$reason\f7)" if defined($reason) and (length($reason) > 0);
		sauer_wall $msg;
	}
}

sub notify_irc_kick {
	my ($kicker, $channel, $victim, $reason) = @_;
	if(sauer_show_joinpart $channel) {
		my $msg = "\f5[irc] \f7$kicker \f6kicked \f7$victim";
		$msg .= " \f6from \f4$channel" if (keys %joinedchans) > 1;
		$msg .= " \f6because: \f7$reason" if defined($reason) and (length($reason) > 0);
		sauer_wall $msg;
	}
	if(sauer_use_talkbot($channel) > 9000) {
		del_sauer_talkbot $victim;
	}
}

sub notify_irc_nick {
	my ($onick, $nnick) = @_;
	my @allchans = keys %joinedchans;
	my $shouldshow = 0;
	foreach my $chan (@allchans) {
		if(exists($joinedchans{$chan}->{$nnick}) and sauer_show_joinpart($chan)) {
			$shouldshow = 1;
		}
	}
	sauer_wall "\f5[irc] \f7$onick \f2is now known as \f7$nnick" if $shouldshow;
	foreach my $chan (@allchans) {
		if(exists($joinedchans{$chan}->{$nnick}) and sauer_use_talkbot($chan) > 9000) {
			ren_sauer_talkbot $onick, $nnick;
			return;
		}
	}
}

sub notify_irc_chat {
	my ($chan, $nick, $msg) = @_;
	# big TODO: filter out color codes
	my $tb = sauer_use_talkbot $chan;
	if($tb < 0) {
		my $m = "\f5[irc] ";
		$m .= "\f4$chan " if (keys %joinedchans) > 1;
		$m .= "\f7$nick: \f0$msg";
		sauer_wall $m;
	}
	elsif($tb > 9000) {
		say_sauer_talkbot($nick, $msg);
	}
	else {
		my ($enick, $emsg) = (sauer_esc_str($nick), sauer_esc_str($msg));
		print "s_talkbot_fakesay $tb $enick $emsg;\n";
	}
}


sub trigger_irc_namereply {
	my $chan = $_[0];
	# if usetalkbot is OVER 9000, make sure to add one bot for each nick
	if(sauer_use_talkbot($chan) > 9000) {
		if(defined $joinedchans{$chan}) {
			foreach my $nick (keys %{$joinedchans{$chan}}) {
				if($nick ne $myircnick) {
					add_sauer_talkbot $nick;
					# TODO: maybe reflect privilege too
				}
			}
		}
	}
}

sub tr_leavechannel {
	my $chan = $_[0];
	if(sauer_use_talkbot($chan) > 9000) {
		foreach my $nick (keys %{$joinedchans{$chan}}) {
			if($nick ne $myircnick) {
				del_sauer_talkbot $nick;
			}
		}
	}
}

sub trigger_irc_part {
	tr_leavechannel $_[0];
}

sub trigger_irc_kick {
	tr_leavechannel $_[0];
}

sub trigger_irc_quit {
	foreach my $chan (keys %joinedchans) {
		tr_leavechannel $chan;
	}
}

my @sauer_ips = ();
my @sauer_names = ();

sub irc_privmsg {
	irc_send "PRIVMSG $_[0] :$_[1]\r\n";
}

sub irc_notice {
	irc_send "NOTICE $_[0] :$_[1]\r\n";
}

sub irc_bcast_msg {
	irc_privmsg join(',', keys %joinedchans), $_[0];
}

sub irc_bcast_notice {
	irc_notice join(',', keys %joinedchans), $_[0];
}

sub process_stdin {
#	if(substr($_[0], 0, 1) eq '/') {
#		my $cmd = substr($_[0], 1);
#		if($cmd eq 'list') {
#			print " * chans and users list:\n";
#			foreach my $chan (keys %joinedchans) {
#				print " * $chan";
#				foreach my $nick (keys %{$joinedchans{$chan}}) {
#					my $privchr = $joinedchans{$chan}->{$nick};
#					print " $privchr$nick";
#				}
#				print "\n";
#			}
#			print " * end of list\n";
#		}
#	}
	if($_[0] =~ /^([a-zA-Z0-9]+): (.+)$/) {
		my ($type, $msg) = ($1, $2);
		if($type eq 'chat') {
			if($msg =~ /^([^ ]+) (\([0-9]+\)|\[[0-9]+:[0-9]+\]): (.*)$/) {
				my ($name, $cn, $text) = ($1, $2, $3);
				irc_bcast_msg("\cB$name\cO \cC06$cn\cO:\cC03 $text");
			}
		}
		elsif($type eq 'connect') {
			if($msg =~ /^client ([0-9]+) \(([0-9A-Za-z.:-]+)\) connected$/) {
				my ($cn, $ip) = ($1, $2);
				# record ip address
				if($showsauerips) {
					$sauer_ips[$cn] = $ip;
				}
				else {
					$sauer_ips[$cn] = '';
				}
			}
			elsif($msg =~ /^([^ ]+) \(([0-9]+)\) joined$/) {
				my ($name, $cn) = ($1, $2);
				# record name
				$sauer_names[$cn] = $name;
				# print message about join
				my $m = "\cC03join:\cO \cB$name\cO \cC06($cn)\cO";
				$m .= " [\cC02,99$sauer_ips[$cn]\cO]" if defined($sauer_ips[$cn]) and (length($sauer_ips[$cn]) > 0);
				irc_bcast_msg($m);
			}
		}
		elsif($type eq 'geoip') {
			if($msg =~ /^client ([0-9]+) connected from (.+)$/) {
				my ($cn, $location) = ($1, $2);
				$sauer_ips[$cn] = $location;
			}
		}
		elsif($type eq 'disconnect') {
			if($msg =~ /^([^ ]+) \(([0-9]+)\) left$/) {
				# re-record name
				$sauer_names[$2] = $1;
			}
			elsif($msg =~ /^client ([0-9]+) \(([0-9A-Za-z.:-]+)\) disconnected(.*)$/) {
				my ($cn, $ip, $rest) = ($1, $2, $3);
				my $name = $sauer_names[$cn];
				$ip = $sauer_ips[$cn] if defined($sauer_ips[$cn]);
				if(defined($name)) {
					my ($action, $reason);
					if($rest =~ /^ by server(.*)$/) {
						$action = "disconnect";
						$rest = $1;
						if($rest =~ /^ because: (.*)$/) { $reason = $1; }
					}
					else { $action = "leave"; }
					my $m = "\cC14$action:\cO \cB$name\cO \cC06($cn)\cO";
					$m .= " [\cC02,99$ip\cO]" if defined($ip) and length($ip) > 0;
					$m .= " because: $reason" if defined($reason);
					irc_bcast_msg($m);
				}
				undef $sauer_ips[$cn];
				undef $sauer_names[$cn];
			}
		}
		elsif($type eq 'rename') {
			if($msg =~ /^([^ ]+) \(([0-9]+)\) is now known as ([^ ]+)/) {
				my ($oname, $cn, $nname) = ($1, $2, $3);
				$sauer_names[$cn] = $nname;
				if($msg =~ /^[^ ]+ \([0-9]+\) is now known as [^ ]+$/) {
					irc_bcast_msg("\cC02rename:\cO \cB$oname\cO \cC06($cn)\cO is now known as \cB$nname\cO");
				}
				elsif($msg = /^[^ ]+ \([0-9]+\) is now known as [^ ]+ by ([^ ]+) \(([0-9]+)\)$/) {
					my ($aname, $acn) = ($1, $2);
					irc_bcast_msg("\cC02rename:\cO \cB$oname\cO \cC06($cn)\cO is now known as \cB$nname\cO by \cB$aname\cO \cC06($acn)\cO");
				}
			}
		}
		elsif($type eq 'master') {
			if($msg =~ /^([^ ]+) \(([0-9]+)\) ([^ ]+) ([^ ]+)(.*)$/) {
				my ($name, $cn, $action, $priv, $rest) = ($1, $2, $3, $4, $5);
				my ($aname, $adesc, $method);
				if($rest =~ /^ as '([^ ]*)' (.*)$/) {
					$aname = $1;
					$rest = $2;
					if($rest =~ /^\[([^\]]+)\] (.*)$/) {
						$adesc = $1;
						$rest = $2;
					}
					if($rest =~ /^\((.+)\)$/) { $method = $1; }
				}
				elsif($rest =~ /^ \((.+)\)$/) { $method = $1; }
				my $m = "\cC02master:\cO \cB$name\cO \cC06($cn)\cO $action \cC03$priv\cO";
				$m .= " as '\cC06,99$aname\cO'" if defined($aname);
				$m .= " [\cC03,99$adesc\cO]" if defined($adesc);
				$m .= " (\cC02,99$method\cO)" if defined($method) and !defined($aname); # when on auth method is obvious
				irc_bcast_msg($m);
			}
		}
		elsif($type eq 'kick') {
			if($msg =~ /^([^ ]+) \(([0-9]+)\) (.*)$/) {
				my ($name, $cn, $rest) = ($1, $2, $3);
				my ($aname, $adesc, $apriv);
				if($rest =~ /^as '([^ ]*)' (.*)$/) {
					$aname = $1;
					$rest = $2;
					if($rest =~ /^\[([^\]]*)\] (.*)$/) {
						$adesc = $1;
						$rest = $2;
					}
					if($rest =~ /^\(([^\)]*)\) (.*)$/) {
						$apriv = $1;
						$rest = $2;
					}
				}
				if($rest =~ /^kicked ([^ ]+) \(([0-9]+)\)(.*)$/) {
					my ($vname, $vcn) = ($1, $2);
					$rest = $3;
					my $reason;
					if($rest =~ /^ because: (.*)$/) {
						$reason = $1;
					}
					# send all info to irc
					my $m = "\cC04kick:\cO \cB$name\cO \cC06($cn)\cO ";
					$m .= "as '\cC06,99$aname\cO' " if defined($aname);
					$m .= "[\cC06,99$adesc\cO] " if defined($adesc);
					$m .= "(\cC03$apriv\cO) " if defined($apriv);
					$m .= "kicked \cB$vname\cO \cC06($vcn)\cO";
					$m .= " because: $reason" if defined($reason);
					irc_bcast_msg($m);
				}
			}
		}
		#else { print ">>>not processing dis message, nigger\n"; }
	}
}

irc_reset;

my $reconnectwait = 0;
MAINLOOP: for(;;) {
	# execute trigger
	trigger_irc_quit;
	%joinedchans = ();
	# if we are quitting, terminate main loop
	last if $quitting;
	# do delay before reconnecting
	sleep $reconnectwait if $reconnectwait > 0;
	last if $quitting;
	# connect to server
	$s = irc_connect($server, $serverport);
	last if $quitting;
	# if failed, schedule next reconnect
	if(!defined($s)) {
		$reconnectwait += 1 if $reconnectwait < 15;
		next MAINLOOP;
	}
	# reset state vars
	irc_reset;
	# first of all, register to server
	irc_send("PASS $ircpass\r\n") if $ircpass;
	irc_send("USER $ircuser 0 $server :$ircreal\r\n");
	irc_send("NICK $ircnick\r\n");
	# we successfully connected
	$reconnectwait = 0;
	my $rin = '';
	my $rout;
	vec($rin, fileno($s), 1) = 1;
	SELECTLOOP: for(;;) {
		vec($rin, fileno(STDIN), 1) = $autojoined && !$quitting; # only accept stdin after we passed autojoin stage
		my $nfd = select($rout = $rin, undef, undef, 3);
		if($nfd < 0) {
			next SELECTLOOP if $! == EINTR;
			die "error in select $!";
		}
		if(vec($rout, fileno($s), 1)) {
			my $ret = recv($s, my $r, 4096, 0);
			# undefined ret - error in receive, probably socket closed by their side
			unless(defined($ret)) {
				close($s);
				next MAINLOOP;
			}
			# get length of received data
			my $rlen = length($r);
			# if we received no data, it's shutdown by their side
			if($rlen <= 0) {
				close($s);
				next MAINLOOP;
			}
			# start search from old length - do not search through old content
			my $searchpos = length($inbuf);
			# append new data
			$inbuf .= $r;
			# $r is no longer needed
			undef $r;
			# calculate total length
			my $totallen = $searchpos + $rlen;
			# mark start position
			my $start = 0;
			# search thru string for newlines
			my $foundnl;
			while(($foundnl = index($inbuf, "\n", $searchpos)) >= 0) {
				# mark line end
				my $lineend = $foundnl;
				# line end -- in case we found \r
				$lineend-- if substr($inbuf, $foundnl-1, 1) eq "\r";
				# extract line from start pos till line end pos
				my $line = substr($inbuf, $start, $lineend-$start);
				# update start and searchpos vars to not iterate thru same data again
				$start = $searchpos = $foundnl + 1;
				# we got line. lets parse it
				process_irc_input($line);
			}
			# remove part of buffer we already processed
			$inbuf = substr($inbuf, $start) if $start > 0;
		}
		if(vec($rout, fileno(STDIN), 1)) {
			# don't use <> or read, since they buffer data. use sysread
			my $line = '';
			for(;;) {
				my $r = sysread STDIN, my $chr, 1;
				last if $r <= 0 or $chr eq "\n";
				$line .= $chr;
			}
			# process line from stdin
			process_stdin($line) if length($line) > 0;
		}

		# if we registered to server, we can send join commands
		if($registered and !$autojoined and !$quitting) {
			irc_joinchan @channels;
			$autojoined = 1;
		}
	}
}

warn "oyasumi.\n";
