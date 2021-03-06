package Bitflu::SourcesBitTorrentKademlia;
################################################################################################
#
# This file is part of 'Bitflu' - (C) 2006-2012 Adrian Ulrich
#
# Released under the terms of The "Artistic License 2.0".
# http://www.opensource.org/licenses/artistic-license-2.0.php

#
# This is not the best Kademlia-Implementation in town.. but it works :-)
#

use strict;
use constant _BITFLU_APIVERSION    => 20120529;
use constant SHALEN                => 20;
use constant K_BUCKETSIZE          => 8;
use constant K_ALPHA               => 3;    # How many locks we are going to provide per sha1
use constant K_QUERY_TIMEOUT       => 15;   # How long we are going to hold a lock
use constant K_ALIVEHUNT           => 18;   # Ping 18 random nodes each 18 seconds
use constant K_MAX_FAILS           => 10;   # Kill node if we reach K_MAX_FAILS/2 punishments (->Punish +=2 / SetNodeAsGood -= 1)
use constant K_REANNOUNCE          => 1500; # ReAnnounce about each 30 minutes
use constant KSTATE_PEERSEARCH     => 1;    # Searching for BitTorrent peers
use constant KSTATE_SEARCH_DEADEND => 2;    # Searching for better kademlia nodes
use constant KSTATE_SEARCH_MYSELF  => 3;    # Searching myself (-> better kademlia nodes)
use constant KSTATE_PAUSED         => 4;    # Download is paused
use constant K_REAL_DEADEND        => 3;    # How many retries to do

use constant BOOT_TRIGGER_COUNT    => 20;      # Boot after passing 20 jiffies
use constant BOOT_SAVELIMIT        => 100;     # Do not save more than 100 kademlia nodes
use constant BOOT_KICKLIMIT        => 8;       # Query 8 nodes per boostrap

use constant TORRENTCHECK_DELY     => 23;     # How often to check for new torrents
use constant G_COLLECTOR           => 300;    # 'GarbageCollectr' + Rotate SHA1 Token after 5 minutes
use constant MAX_TRACKED_HASHES    => 250;    # How many torrents we are going to track
use constant MAX_TRACKED_PEERS     => 100;    # How many peers (per torrent) we are going to track
use constant MAX_TRACKED_SEND      => 30;     # Do not send more than 30 peers per request

use constant MIN_KNODES            => 5;      # Try to bootstrap until we reach this limit
use constant RUN_TIME              => 3;
use constant MAX_KAD_TRAFFIC       => 1024*5*RUN_TIME; # never-ever do more than 5kbps

use constant K_DEBUG               => 0;      # remove ->debug calls

use constant TOKEN_SIZE            => 16;


################################################################################################
# Register this plugin
sub register {
	my($class, $mainclass) = @_;
	
	my $prototype = { super=>undef,lastrun => 0, xping => { list => {}, cache=>[], trigger => 0 },
	                 _addnode => { totalnodes => 0, badnodes => 0, goodnodes => 0, hashes=>{} }, _killnode => {},
	                 huntlist => {}, votelist=>{}, checktorrents_at  => 0, gc_lastrun => 0, topclass=>undef,
	                 bootstrap_trigger => 0, bootstrap_credits => 0,
	                 memlist => { announce => {}, vote=> {} },
	                };
	
	my $topself   = {super=>$mainclass, proto=>{}, bytes_sent=>0, k_bps=>0, overloaded=>0 };
	bless($topself,$class);
	
	my @protolist = ();
	push(@protolist,4) if $mainclass->Network->HaveIPv4;
	push(@protolist,6) if $mainclass->Network->HaveIPv6;
	
	
	
	my $node_id = $mainclass->Tools->sha1(($mainclass->Configuration->GetValue('kademlia_idseed') || $topself->GetRandomBytes(1024) ));
	
	foreach my $proto (@protolist) {
		my $this = $mainclass->Tools->DeepCopy($prototype);
		bless($this,$class."::IPv$proto");
		map( {$this->RotateToken} (1..2) ); # init both token values
		$this->{super}         = $mainclass;
		$this->{topclass}      = $topself;
		$this->{protoname}     = "IPv$proto";
		$topself->{tcp_bind}   = $this->{tcp_bind} = ($mainclass->Configuration->GetValue('torrent_bind') || 0); # May be null
		$topself->{tcp_port}   = $this->{tcp_port} = $mainclass->Configuration->GetValue('torrent_port')           or $this->panic("'torrent_port' not set in configuration");
		$topself->{my_sha1}    = $this->{my_sha1}  = $node_id;
		$topself->{sw_sha1}    = $this->{sw_sha1}  = _switchsha($this->{my_sha1});
		$topself->{ver_str}    = $this->{ver_str}  = "BF-".join('.', map( ($topself->{super}->GetVersion)[$_], (0..1) ) );
		$topself->{proto}->{$proto} = $this;
	}
	
	$mainclass->Configuration->SetValue('kademlia_idseed', 0) unless defined($mainclass->Configuration->GetValue('kademlia_idseed'));
	$mainclass->Configuration->RuntimeLockValue('kademlia_idseed');
	
	return $topself;
}

################################################################################################
# Init plugin
sub init {
	my($topself) = @_;
	
	
	my $udp_socket = $topself->{super}->Network->NewUdpListen(ID=>$topself, Bind=>$topself->{tcp_bind}, Port=>$topself->{tcp_port},
	                                  Callbacks => { Data => '_Network_Data' } ) or $topself->panic("Cannot create udp socket on $topself->{tcp_bind}:$topself->{tcp_port}");
	
	my $bt_hook    = $topself->{super}->GetRunnerTarget('Bitflu::DownloadBitTorrent');
	
	foreach my $proto (keys(%{$topself->{proto}})) {
		$topself->info("Firing up kademlia support for IPv$proto ...");
		
		my $this_self = $topself->{proto}->{$proto};
		
		$this_self->{bittorrent}        = $bt_hook or $topself->panic("Cannot add bittorrent hook");
		$this_self->StartHunting($this_self->{sw_sha1},KSTATE_SEARCH_MYSELF); # Add myself to find close peers
		$this_self->{super}->Admin->RegisterCommand('kdebug'.$proto    ,$this_self, 'Command_Kdebug'   , "ADVANCED: Dump Kademlia nodes");
		$this_self->{super}->Admin->RegisterCommand('kannounce'.$proto ,$this_self, 'Command_Kannounce', "ADVANCED: Dump tracked kademlia announces");
		$this_self->{super}->Admin->RegisterCommand('kvotes'.$proto    ,$this_self, 'Command_Kvotes'   , "ADVANCED: Dump tracked kademlia votes");
		$this_self->{bootstrap_trigger} = 1;
		$this_self->{bootstrap_credits} = 4; # Try to boot 4 times
		$this_self->{udpsock}           = $udp_socket;
	}
	
	
	$topself->{super}->AddRunner($topself) or $topself->panic("Cannot add runner");
	
	$topself->info("BitTorrent-Kademlia plugin loaded. Using udp port $topself->{tcp_port}, NodeID: ".unpack("H*",$topself->{my_sha1}));
	
	
	return 1;
}


################################################################################################
# Mainsub called by bitflu.pl
sub run {
	my($topself,$NOWTIME) = @_;
	
	$topself->{k_bps}      = ($topself->{bytes_sent}/1024/RUN_TIME);
	$topself->{bytes_sent} = 0;
	$topself->{overloaded} = 0;
	
	foreach my $this_self (values(%{$topself->{proto}})) {
		$this_self->_proto_run($NOWTIME);
	}
	return RUN_TIME;
}

################################################################################################
# Dispatch payload to correct network subclass
sub _Network_Data {
	my($topself,$sock,$buffref, $this_ip, $this_port) = @_;
	
	if(exists($topself->{proto}->{6}) && $topself->{super}->Network->IsNativeIPv6($this_ip)) {
		my $eip = $topself->{proto}->{6}->{super}->Network->ExpandIpV6($this_ip);
		$topself->{proto}->{6}->NetworkHandler($sock,$buffref,$eip,$this_port);
	}
	elsif(exists($topself->{proto}->{4}) && $topself->{super}->Network->IsNativeIPv4($this_ip)) {
		$topself->{proto}->{4}->NetworkHandler($sock,$buffref,$this_ip,$this_port);
	}
	else {
		$topself->warn("What is $this_ip ?!");
	}
}


################################################################################################
# Display all tracked torrents
sub Command_Kannounce {
	my($self,@args) = @_;
	
	my @A = ();
	push(@A, [undef, "Tracked torrents -> Own id: ".unpack("H*",$self->{my_sha1})]);
	foreach my $sha1 (keys(%{$self->{memlist}->{announce}})) {
		push(@A, [1, "=> ".unpack("H*",$sha1)]);
		foreach my $nid (keys(%{$self->{memlist}->{announce}->{$sha1}})) {
			my $ref = $self->{memlist}->{announce}->{$sha1}->{$nid};
			push(@A, [undef, "   ip => $ref->{ip} ; port => $ref->{port} ; seen => $ref->{_seen}"]);
		}
	}
	
	return({OK=>1, MSG=>\@A, SCRAP=>[]});
}

################################################################################################
# Dump 'votes' memlist
sub Command_Kvotes {
	my($self,@args) = @_;
	
	my @A = ();
	push(@A, [undef, "Tracked votes"]);
	foreach my $sha1 (keys(%{$self->{memlist}->{vote}})) {
		push(@A, [1, "=> ".unpack("H*",$sha1)]);
		foreach my $nid (keys(%{$self->{memlist}->{vote}->{$sha1}})) {
			my $ref = $self->{memlist}->{vote}->{$sha1}->{$nid};
			push(@A, [undef, " peer => $nid ; vote => $ref->{vote} ; seen => $ref->{_seen}"]);
		}
	}
	
	return({OK=>1, MSG=>\@A, SCRAP=>[]});
}


################################################################################################
# Display debug information / nodes breakdown
sub Command_Kdebug {
	my($self,@args) = @_;
	
	my @A       = ();
	my $arg1    = ($args[0] || '');
	my $arg2    = ($args[1] || '');
	my $nn      = 0;
	my $nv      = 0;
	my $NOWTIME = $self->{super}->Network->GetTime;
	
	push(@A, [1, "--== Kademlia Debug ==--"]);
	
	
	push(@A, [4, "Known Kademlia Nodes"]);
	foreach my $val (values(%{$self->{_addnode}->{hashes}})) {
		push(@A, [undef, "sha1=>".unpack("H*",$val->{sha1}).", good=>$val->{good}, lastseen=>$val->{lastseen}, fails=>$val->{rfail}, Ip=>".$val->{ip}.":".$val->{port}]);
		$nn++;
		$nv++ if $val->{good};
	}
	
	push(@A, [0,''],[4, "Registered BitTorrent hashes"]);
	foreach my $key (keys(%{$self->{huntlist}})) {
		my $xref          = $self->{huntlist}->{$key};
		my $next_announce = $xref->{nextannounce} - $NOWTIME;
		$next_announce    = ( $next_announce < 60 ? '-' : int($next_announce/60)." min.");
		
		push(@A,[3, " --> ".unpack("H*",$key)]);
		push(@A,[1, "     BestBucket: ".$xref->{bestbuck}. ", State: ".$self->GetState($key).", TransactionID: ".unpack("H*",$xref->{trmap})]);
		push(@A,[1, "     NextAnnounce: ".$next_announce.", Announces: ".$self->{huntlist}->{$key}->{announce_count}]);
	}
	
	
	if($arg1 eq '-v' or $arg1 eq '-vv') {
		my $sha1 = pack("H*", $arg2);
		   $sha1 = $self->{sw_sha1} unless exists $self->{huntlist}->{$sha1};
		my $bref = $self->{huntlist}->{$sha1}->{buckets};
		
		push(@A, [0, '']);
		push(@A, [1, "Buckets of ".unpack("H*",$sha1)]);
		
		
		foreach my $bnum (sort({$a<=>$b} keys(%$bref))) {
			my $bs = int(@{$bref->{$bnum}});
			next unless $bs;
			push(@A, [2, sprintf("bucket # %3d -> $bs node(s) ",$bnum)]);
			foreach my $xbuck (@{$bref->{$bnum}}) {
				push(@A, [0, " ".unpack("H*",$xbuck->{sha1})]) if $arg1 eq '-vv';
			}
		}
		
	}
	
	if($arg1 eq '-change') {
		$self->_ChangeOwnNodeId;
	}
	
	my $percent = sprintf("%5.1f%%", ($nn ? 100*$nv/$nn : 0));
	
	push(@A, [0, '']);
	push(@A, [0, "Current mode                   : ".($self->MustBootstrap ? 'bootstrap' : 'running')]);
	push(@A, [0, sprintf("Number of known kademlia peers : %5d",$nn) ]);
	push(@A, [0, sprintf("Good (reachable) nodes         : %5d (%s)",$nv,$percent) ]);
	push(@A, [0, sprintf("Ping-Cache size                : %5d", int(@{$self->{xping}->{cache}}))]);
	push(@A, [0, sprintf("Outstanding ping replies       : %5d", int(keys(%{$self->{xping}->{list}})))]);
	push(@A, [0, sprintf("Outgoing traffic               : ~ %5.1f kbps (%s)", $self->{topclass}->{k_bps}, ( $self->{topclass}->{overloaded} ? 'overloaded':'ok') )]);
	push(@A, [0, '']);
	return({MSG=>\@A, SCRAP=>[]});
}




################################################################################################
# Run !
sub _proto_run {
	my($self,$NOWTIME) = @_;
	
	if($self->{gc_lastrun} < $NOWTIME-(G_COLLECTOR)) {
		# Rotate SHA1 Token
		$self->{gc_lastrun} = $NOWTIME;
		$self->RotateToken;
		$self->MemlistCleaner($self->{memlist}->{announce});
		$self->MemlistCleaner($self->{memlist}->{vote});
	}
	
	if($self->{bootstrap_trigger} && $self->{bootstrap_trigger}++ == BOOT_TRIGGER_COUNT) {
		$self->{bootstrap_trigger} = ( --$self->{bootstrap_credits} > 0 ? 1 : 0 ); # ReEnable only if we have credits left
		
		if($self->MustBootstrap) {
			$self->{super}->Admin->SendNotify("No kademlia $self->{protoname} peers, starting bootstrap... (Is udp:$self->{tcp_port} open?)");
			foreach my $node ($self->GetBootNodes) {
				$node->{ip} = $self->Resolve($node->{ip});
				next unless $node->{ip};
				$self->BootFromPeer($node);
			}
		}
		else {
			$self->{bootstrap_trigger} = 0; # We got some nodes -> Disable bootstrapping
		}
	}
	
	
	
	if($self->{checktorrents_at} < $NOWTIME) {
		$self->{checktorrents_at} = $NOWTIME + TORRENTCHECK_DELY;
		$self->CheckCurrentTorrents;
		$self->SaveBootNodes;
	}
	
	
	# Check each torrent/key (target) that we are hunting right now
	my $hcreds = 4;
	foreach my $huntkey (List::Util::shuffle keys(%{$self->{huntlist}})) {
		my $cached_best_bucket  = $self->{huntlist}->{$huntkey}->{bestbuck};
		my $cached_next_huntrun = $self->{huntlist}->{$huntkey}->{nexthunt};
		my $cstate              = $self->{huntlist}->{$huntkey}->{state};
		my $fastboot            = $self->{huntlist}->{$huntkey}->{fastboot};
		my $running_qtype       = undef;
		my $xdelay              = ( $fastboot ? RUN_TIME : K_QUERY_TIMEOUT );
		next if ($cached_next_huntrun > $NOWTIME); # still searching
		next if $cstate == KSTATE_PAUSED;          # Search is paused
		next if $hcreds-- < 1;                     # too many hunts
		
		$self->DelayHunt($huntkey, $xdelay+int(rand($hcreds)));
		
		if($cached_best_bucket == $self->{huntlist}->{$huntkey}->{deadend_lastbestbuck}) {
			$self->{huntlist}->{$huntkey}->{deadend}++; # No progress made
		}
		else {
			$self->{huntlist}->{$huntkey}->{deadend_lastbestbuck} = $cached_best_bucket;
			$self->{huntlist}->{$huntkey}->{deadend} = 0;
		}
		
		
		if($self->{huntlist}->{$huntkey}->{deadend} >= K_REAL_DEADEND) { # Looks like we won't go anywhere..
			$self->{huntlist}->{$huntkey}->{deadend}  = 0;
			$self->{huntlist}->{$huntkey}->{fastboot} = 0;
			
			if($cstate == KSTATE_PEERSEARCH) {
				# Switch mode -> search (again) for a deadend
				$self->SetState($huntkey,KSTATE_SEARCH_DEADEND);
				$self->TriggerHunt($huntkey);
			}
			elsif($cstate == KSTATE_SEARCH_DEADEND) {
				# We reached a deadend -> Announce (if we have to) and restart search.
				if($self->{huntlist}->{$huntkey}->{nextannounce} < $NOWTIME) {
					my $peers = 0;
					
					if(exists($self->{votelist}->{$huntkey})) {
						$peers = $self->QueryVotes($huntkey);
					}
					else {
						$peers = $self->ReAnnounceOurself($huntkey);
					}
					
					if($peers > 0) {
						$self->{huntlist}->{$huntkey}->{nextannounce} = $NOWTIME + K_REANNOUNCE + int(rand(200));
						$self->{huntlist}->{$huntkey}->{announce_count}++;
					}
				}
				
				$self->SetState($huntkey,KSTATE_PEERSEARCH);
			}
			next;
		}
		
		if($cstate == KSTATE_PEERSEARCH) {
			$running_qtype = "command_getpeers"; # We are searching for VALUES
		}
		elsif($cstate == KSTATE_SEARCH_DEADEND) {
			$running_qtype = "command_findnode"; # We search better peers
		}
		elsif($cstate == KSTATE_SEARCH_MYSELF) {
			$running_qtype = "command_findnode"; # We are searching near peers
		}
		else {
			$self->panic("Unhandled state for ".unpack("H*",$huntkey).": $cstate");
		}
		
		
		# fixme: From time-to-time we should walk forward and try to fill up non-full buckets
		
		
		# walk bucklist backwards
		for(my $i=$cached_best_bucket; $i >= 0; $i--) {
			next unless defined($self->{huntlist}->{$huntkey}->{buckets}->{$i}); # -> Bucket empty
			foreach my $buckref (List::Util::shuffle(@{$self->{huntlist}->{$huntkey}->{buckets}->{$i}})) { # pick some random nodes from bucket (well: we should get the 3 best - but this helps us learning tokens)
				my $lockstate = $self->GetAlphaLock($huntkey,$buckref);
				
				if($lockstate == 1) { # Just freshly locked
					$self->SetQueryType($buckref,$running_qtype);
					$self->UdpWrite({ip=>$buckref->{ip}, port=>$buckref->{port}, cmd=>$self->$running_qtype($huntkey)});
				}
				elsif($lockstate == 0) { # all locks are in use -> we can escape all loops
					goto BUCKWALK_END;
				}
			}
		}
		BUCKWALK_END:
	}
	
	
	# Ping some nodes to check if them are still alive
	$self->AliveHunter();
	# Really remove killed nodes
	$self->RunKillerLoop();
	
	return 0;
}



sub NetworkHandler {
	my($self,$sock,$buffref,$THIS_IP, $THIS_PORT) = @_;
	
	my $THIS_BUFF = $$buffref;
	
	if(!$THIS_PORT or !$THIS_IP) {
		$self->warn("Ignoring data from <$sock>, no peerhost"); # shouldn't happen -> fixme: can be removed?
		return;
	}
	elsif(length($THIS_BUFF) == 0) {
		$self->warn("$THIS_IP : $THIS_PORT sent no data");
		return;
	}
	
	my $btdec = $self->{super}->Tools->BencDecode($THIS_BUFF);
	
	if(ref($btdec) ne "HASH" or !defined($btdec->{t}) or !defined($btdec->{y})) {
		$self->debug("Garbage received from $THIS_IP:$THIS_PORT") if K_DEBUG;
		return;
	}
	
		if($btdec->{y} eq 'q') {
			# -> QUERY
			
			
			# Check if query fulfills basic syntax
			if(length($btdec->{a}->{id}) != SHALEN or $btdec->{a}->{id} eq $self->{my_sha1}) {
				$self->debug("$THIS_IP:$THIS_PORT ignoring malformed query");
				return;
			}
			
			
			# Try to add node:
			$self->AddNode({ip=>$THIS_IP, port=>$THIS_PORT, sha1=>$btdec->{a}->{id}});
			
			# -> Requests sent to us
			if($self->{topclass}->{overloaded}) {
				# do not send a reply if we are overloaded (after adding the node)
			}
			elsif($btdec->{q} eq "ping") {
				$self->UdpWrite({ip=>$THIS_IP, port=>$THIS_PORT, cmd=>$self->reply_ping($btdec)});
				$self->debug("$THIS_IP:$THIS_PORT : Pong reply sent") if K_DEBUG;
			}
			elsif($btdec->{q} eq 'find_node' && length($btdec->{a}->{target}) == SHALEN) {
				$self->UdpWrite({ip=>$THIS_IP, port=>$THIS_PORT, cmd=>$self->reply_findnode($btdec)});
				$self->debug("$THIS_IP:$THIS_PORT (find_node): sent kademlia nodes to peer") if K_DEBUG;
			}
			elsif($btdec->{q} eq 'get_peers' && length($btdec->{a}->{info_hash}) == SHALEN) {
				unless( $self->HandleGetPeersCommand($THIS_IP,$THIS_PORT,$btdec) ) { # -> Try to send some peers
					# failed? -> send kademlia nodes
					$self->UdpWrite({ip=>$THIS_IP, port=>$THIS_PORT, cmd=>$self->reply_getpeers($btdec)});
					
					$self->debug("$THIS_IP:$THIS_PORT (get_peers) : sent kademlia nodes to peer") if K_DEBUG;
				}
			}
			elsif($btdec->{q} eq 'announce_peer' && length($btdec->{a}->{info_hash}) == SHALEN && $btdec->{a}->{port}) {
				
				if( $self->TokenIsValid($btdec->{a}->{token}) ) {
					if($self->MemlistAddItem($self->{memlist}->{announce}, $btdec->{a}->{info_hash}, $btdec->{a}->{id}, { ip=>$THIS_IP, port=>$btdec->{a}->{port}})) {
						# Report success
						$self->UdpWrite({ip=>$THIS_IP, port=>$THIS_PORT, cmd=>$self->reply_ping($btdec)});
					}
				}
				else {
					# invalid/outdated token -> drop announce and send error back
					$self->UdpWrite({ip=>$THIS_IP, port=>$THIS_PORT, cmd=>$self->reply_tokenerror($btdec)});
				}
				
			}
			elsif($btdec->{q} eq 'vote' && length($btdec->{a}->{target}) == SHALEN) {
				# -> utorrent beta message: implement-me-after-spec-is-final
				my $vtarget = $btdec->{a}->{target};
				my $vote    = $btdec->{a}->{vote};
				$self->debug("VOTE from $THIS_IP for ".unpack("H*",$btdec->{a}->{target})." is $btdec->{a}->{vote}");
				
				if($vote > 0 && $vote <= 5 && $self->TokenIsValid($btdec->{a}->{token})) {
					$self->MemlistAddItem($self->{memlist}->{vote}, $vtarget, $THIS_IP, { vote=>$vote });
					# no need to reply here
				}
				
				if(my $vref = $self->{memlist}->{vote}->{$vtarget}) {
					# got data: count votes from memlist:
					my @this_votes = qw(0 0 0 0 0);
					map( { $this_votes[($_->{vote})-1]++ } values(%{$vref}) );
					
					# ...and send it to peer:
					$self->UdpWrite({ip=>$THIS_IP, port=>$THIS_PORT, cmd=>$self->reply_vote($btdec, \@this_votes)});
				}
				else {
					# got no data -> send an empty (aka. ping) reply
					$self->UdpWrite({ip=>$THIS_IP, port=>$THIS_PORT, cmd=>$self->reply_ping($btdec)});
				}
				
			}
			else {
				$self->info("Unhandled QueryType $btdec->{q}");
			}
		}
		elsif($btdec->{y} eq "r") {
			# -> Response
			my $peer_shaid = $btdec->{r}->{id};
			my $tr2hash    = $self->tr2hash($btdec->{t}); # Reply is for this SHA1
			
			$self->NormalizeReplyDetails($btdec);
			
			if(length($peer_shaid) != SHALEN or $peer_shaid eq $self->{my_sha1}) {
				$self->debug("$THIS_IP:$THIS_PORT ignoring malformed response");
				return;
			}
			
			if($self->{trustlist}->{"$THIS_IP:$THIS_PORT"}) {
				$self->info("$THIS_IP:$THIS_PORT -> Bootstrap done!");
				delete($self->{trustlist}->{"$THIS_IP:$THIS_PORT"});
				my $addnode = $self->AddNode({ip=>$THIS_IP,port=>$THIS_PORT, sha1=>$peer_shaid});
				if(!defined($addnode)) {
					$self->info("$THIS_IP:$THIS_PORT -> bootnode was not added");
					return;
				}
			}
			
			if(!$self->ExistsNodeHash($peer_shaid)) {
				$self->debug("$THIS_IP:$THIS_PORT (".unpack("H*",$peer_shaid).") sent response to unasked question. no thanks.");
				return;
			}
			elsif(!defined($tr2hash)) {
				$self->debug("$THIS_IP:$THIS_PORT sent invalid hash TR");
				return;
			}
			
			
			my $this_node  = $self->GetNodeFromHash($peer_shaid);
			my $node_qtype = $self->GetQueryType($this_node);
			
			if($this_node->{ip} ne $THIS_IP) {
				# $self->warn(unpack("H*",$this_node->{sha1})." owned by $this_node->{ip}, but payload was sent by $THIS_IP . dropping!");
				return;
			}
			
			
			$self->panic if length($tr2hash) != SHALEN; # paranoia check - remove me
			$self->SetNodeAsGood({hash=>$peer_shaid,token=>$btdec->{r}->{token}});
			$self->FreeSpecificAlphaLock($tr2hash,$peer_shaid);
			
			
			# Accept 'nodes' if we asked 'anything'. Accept it event without a question while bootstrapping
			if($btdec->{r}->{nodes} && ($node_qtype ne '' or $self->MustBootstrap ) ) {
				my $allnodes = $self->_decodeNodes($btdec->{r}->{nodes});
				my $cbest    = $self->{huntlist}->{$tr2hash}->{bestbuck};
				
				foreach my $x (@$allnodes) {
					next if length($x->{sha1}) != SHALEN;
					next if !$x->{port} or !$x->{ip}; # Do not add garbage
					next unless defined $self->AddNode({sha1=>$x->{sha1}, port=>$x->{port}, ip=>$x->{ip}, norefresh=>1});
				}
				
				if($cbest < $self->{huntlist}->{$tr2hash}->{bestbuck}) {
					# We advanced -> ask new nodes ASAP
					$self->TriggerHunt($tr2hash);
					$self->ReleaseAllAlphaLocks($tr2hash);
				}
				# Clean Querytrust:
				$self->SetQueryType($this_node,'');
			}
			# Accept values only as a reply to getpeers:
			if($btdec->{r}->{values} && ref($btdec->{r}->{values}) eq 'ARRAY' && $node_qtype eq 'command_getpeers') {
				my $all_hosts = $self->_decodeIPs($btdec->{r}->{values});
				my $this_sha  = unpack("H*", $tr2hash);
				$self->debug("$this_sha: new BitTorrent nodes from $THIS_IP:$THIS_PORT (".int(@$all_hosts).")");
				
				# Tell bittorrent about new nodes:
				if($self->{bittorrent}->Torrent->ExistsTorrent($this_sha)) {
					$self->{bittorrent}->Torrent->GetTorrent($this_sha)->AddNewPeers(@$all_hosts);
				}
				
				# Stop asking the same nodes for BT-Nodes
				if($self->GetState($tr2hash) == KSTATE_PEERSEARCH) {
					$self->SetState($tr2hash, KSTATE_SEARCH_DEADEND);
					$self->DelayHunt($tr2hash, K_QUERY_TIMEOUT*2);
				}
				# Clean Querytrust
				$self->SetQueryType($this_node,'');
			}
			
			if(exists($btdec->{r}->{v}) && ref($btdec->{r}->{v}) eq 'ARRAY') {
				my $stars = $self->GetRatingFromArray(@{$btdec->{r}->{v}});
				$self->UpdateRemoteRating($tr2hash, $stars);
			}
			
		}
		elsif($btdec->{y} eq 'e') {
			# just for debugging:
			# $self->warn("$THIS_IP [$THIS_PORT] \n".Data::Dumper::Dumper($btdec));
		}
		else {
			$self->debug("$THIS_IP:$THIS_PORT: Ignored packet with suspect 'y' tag");
		}
}

sub debug { my($self, $msg) = @_; $self->{super}->debug("Kademlia: ".$msg); }
sub info  { my($self, $msg) = @_; $self->{super}->info("Kademlia: ".$msg);  }
sub warn  { my($self, $msg) = @_; $self->{super}->warn("Kademlia: ".$msg);  }
sub panic { my($self, $msg) = @_; $self->{super}->panic("Kademlia: ".$msg); }



########################################################################
# Reply to get_peers command: true if we sent something, false if we failed
sub HandleGetPeersCommand {
	my($self,$ip,$port,$btdec) = @_;
	
	if(exists($self->{memlist}->{announce}->{$btdec->{a}->{info_hash}})) {
		my @nodes    = ();
		foreach my $rk (List::Util::shuffle(keys(%{$self->{memlist}->{announce}->{$btdec->{a}->{info_hash}}}))) {
			my $r = $self->{memlist}->{announce}->{$btdec->{a}->{info_hash}}->{$rk} or $self->panic;
			push(@nodes, $self->_encodeNode({sha1=>'', ip=>$r->{ip}, port=>$r->{port}}));
			last if int(@nodes) > MAX_TRACKED_SEND;
		}
		$self->UdpWrite({ip=>$ip, port=>$port, cmd=>$self->reply_values($btdec,\@nodes)});
		$self->debug("$ip:$port (get_peers) : sent ".int(@nodes)." BitTorrent nodes to peer");
		return 1;
	}
	else {
		return 0;
	}
}


########################################################################
# Updates on-disk boot list
sub SaveBootNodes {
	my($self) = @_;
	
	my $nref = {};
	my $ncnt = 0;
	
	foreach my $node (values(%{$self->{_addnode}->{hashes}})) {
		if($node->{good} && $node->{rfail} == 0) {
			$nref->{$node->{ip}} = $node->{port};
			last if (++$ncnt >= BOOT_SAVELIMIT);
		}
	}
	
	if($ncnt > 0) {
		$self->{super}->Storage->ClipboardSet($self->GetCbId, $self->{super}->Tools->RefToCBx($nref));
	}
}

########################################################################
# Returns some bootable nodes
sub GetBootNodes {
	my($self) = @_;
	
	my @B   = $self->GetHardcodedBootNodes;
	my @R   = ();
	my $cnt = 0;
	my $ref = $self->{super}->Tools->CBxToRef($self->{super}->Storage->ClipboardGet($self->GetCbId));
	
	foreach my $ip (keys(%$ref)) {
		push(@B,{ip=>$ip, port=>$ref->{$ip}});
	}
	
	foreach my $item (List::Util::shuffle(@B)) {
		push(@R,$item);
		last if ++$cnt >= BOOT_KICKLIMIT;
	}
	return @R;
}


sub CheckCurrentTorrents {
	my($self) = @_;
	my %known_torrents = map { $_ => 1 } $self->{bittorrent}->Torrent->GetTorrents;
	my @to_stop        = ();
	foreach my $sha1 (keys(%{$self->{huntlist}})) {
		my $up_hsha1 = unpack("H40",$sha1);
		if($self->GetState($sha1) == KSTATE_SEARCH_MYSELF) {
			next; # never remove our own search
		}
		elsif(exists($self->{votelist}->{$sha1})) {
			next; # not removed here
		}
		elsif(delete($known_torrents{$up_hsha1})) {
			if($self->{bittorrent}->Torrent->GetTorrent($up_hsha1)->IsPaused) {
				$self->SetState($sha1, KSTATE_PAUSED);
			}
			elsif($self->GetState($sha1) == KSTATE_PAUSED) {
				$self->SetState($sha1, KSTATE_SEARCH_DEADEND);
			}
		}
		else {
			push(@to_stop, $sha1); # stopping must be done outside of the loop
		}
	}
	
	# stop downloads
	foreach my $sha1 (@to_stop) {
		$self->StopHunting($sha1);
		$self->StopVoteHunt($sha1);
	}
	
	# add new downloads
	foreach my $up_hsha1 (keys(%known_torrents)) {
		my $sha1 = pack("H40", $up_hsha1);
		
		next if $self->{bittorrent}->Torrent->GetTorrent($up_hsha1)->IsPrivate;
		next if $sha1 eq $self->{sw_sha1}; # Adding our own SHA1 as a torrent is a bad idea.
		
		$self->StartHunting($sha1, KSTATE_SEARCH_DEADEND);
		$self->StartVoteHunt($sha1);
	}
}

########################################################################
# Starts a 'vote' hunt of given info_hash
sub StartVoteHunt {
	my($self, $info_hash) = @_;
	my $vote_sha = $self->{super}->Tools->sha1($info_hash."rating");
	$self->StartHunting($vote_sha, KSTATE_SEARCH_DEADEND);
	$self->{votelist}->{$vote_sha} = { info_hash=>$info_hash };
}

########################################################################
# Stops the vote hunt of given info hash
sub StopVoteHunt {
	my($self, $info_hash) = @_;
	my $vote_sha = $self->{super}->Tools->sha1($info_hash."rating");
	$self->StopHunting($vote_sha);
	delete($self->{votelist}->{$vote_sha}) or $self->panic("vote was not active");
}

########################################################################
# Add given hash to 'huntlist'
sub StartHunting {
	my($self,$sha,$initial_state) = @_;
	$self->panic("Invalid SHA1")             if length($sha) != SHALEN;
	$self->panic("This SHA1 has been added") if defined($self->{huntlist}->{$sha});
	$self->panic("No initial state given!")  if !$initial_state;
	$self->debug("+ Hunt ".unpack("H*",$sha));
	
	
	my $tr_id = undef;
	
	for(my $i=0; $i<= 0xFFFFFF; $i++) {
		my $guess = pack("H6",$self->{super}->Tools->sha1($self.$sha.rand())); # throw some randomness at it
		if($guess && !exists($self->{trmap}->{$guess})) { # not null and not existing? -> hit!
			$tr_id = $guess;
			last;
		}
	}
	
	unless(defined($tr_id)) {
		$self->warn("No free transaction id found: too many torrents");
		return undef;
	}
	
	my $nowtime               = $self->{super}->Network->GetTime;
	$self->{trmap}->{$tr_id}  = $sha;
	$self->{huntlist}->{$sha} = { addtime=>$nowtime, trmap=>$tr_id, state=>$initial_state, announce_count => 0,
	                              bestbuck => 0, nexthunt => 0, fastboot=>1, deadend => 0, nextannounce => $nowtime+300, deadend_lastbestbuck => 0};
	
	foreach my $old_sha (keys(%{$self->{_addnode}->{hashes}})) { # populate routing table for new target -> try to add all known nodes
		$self->_inject_node_into_huntbucket($old_sha,$sha);
	}
	return 1;
}


sub _inject_node_into_huntbucket {
	my($self,$new_node,$hunt_node) = @_;
	
	$self->panic("Won't inject non-existent node")          unless $self->ExistsNodeHash($new_node);
	$self->panic("Won't inject into non-existent huntlist") unless defined($self->{huntlist}->{$hunt_node});
	
	my $bucket = int(_GetBucketIndexOf($new_node,$hunt_node));
	if(!defined($self->{huntlist}->{$hunt_node}->{buckets}->{$bucket}) or int(@{$self->{huntlist}->{$hunt_node}->{buckets}->{$bucket}}) < K_BUCKETSIZE) {
		# Add new node to current bucket and fixup bestbuck (if it is better)
		my $nref = $self->GetNodeFromHash($new_node);
		push(@{$self->{huntlist}->{$hunt_node}->{buckets}->{$bucket}}, $nref);
		$nref->{refcount}++;
		$self->{huntlist}->{$hunt_node}->{bestbuck} = $bucket if $bucket >= $self->{huntlist}->{$hunt_node}->{bestbuck}; # Set BestBuck cache
		return 1;
	}
	return undef;
}


sub StopHunting {
	my($self,$sha) = @_;
	$self->panic("Unable to remove non-existent $sha") unless defined($self->{huntlist}->{$sha});
	$self->panic("Killing my own SHA1-ID is not permitted") if $self->{huntlist}->{$sha}->{state} == KSTATE_SEARCH_MYSELF;
	
	my $xtr = $self->{huntlist}->{$sha}->{trmap};
	$self->panic("No TR for $sha!") unless $xtr;
	foreach my $val (values %{$self->{huntlist}->{$sha}->{buckets}}) {
		foreach my $ref (@$val) {
			$ref->{refcount}--;
			
			if($ref->{refcount} != $self->GetNodeFromHash($ref->{sha1})->{refcount}) {
				$self->panic("Refcount fail: $ref->{refcount}");
			}
			elsif($ref->{refcount} == 0) {
				$self->KillNode($ref->{sha1});
			}
			elsif($ref->{refcount} < 1) {
				$self->panic("Assert refcount >= 1 failed; $ref->{refcount}");
			}
		}
	}
	delete($self->{trmap}->{$xtr})     or $self->panic;
	delete($self->{huntlist}->{$sha})  or $self->panic;
	return 1;
}


sub SetState {
	my($self,$sha,$state) = @_;
	$self->panic("Invalid SHA: $sha") unless defined($self->{huntlist}->{$sha});
	return $self->{huntlist}->{$sha}->{state} = $state;
}

sub GetState {
	my($self,$sha) = @_;
	$self->panic("Invalid SHA: $sha") unless defined($self->{huntlist}->{$sha});
	return $self->{huntlist}->{$sha}->{state};
}

sub TriggerHunt {
	my($self,$sha) = @_;
	$self->panic("Invalid SHA: $sha") unless defined($self->{huntlist}->{$sha});
	$self->debug(unpack("H*",$sha)." -> hunt trigger");
	return $self->{huntlist}->{$sha}->{nexthunt} = 0;
}

sub DelayHunt {
	my($self,$sha,$delay) = @_;
	$self->panic("Invalid SHA: $sha") unless defined($self->{huntlist}->{$sha});
	$self->debug(unpack("H*",$sha)." + delay of $delay sec");
	return $self->{huntlist}->{$sha}->{nexthunt} = $self->{super}->Network->GetTime + $delay;
}


########################################################################
# Modify our own node_id while running
sub _ChangeOwnNodeId {
	my($self, $seed) = @_;
	
	my $old_id = $self->{my_sha1};
	my $old_sw = $self->{sw_sha1};
	my $new_id = $self->{super}->Tools->sha1( $seed || rand().rand() ); # fixme: needs more randomness
	
	$self->info("Changing own node id from ".unpack("H*",$old_id)." to ".unpack("H*",$new_id));
	
	# introduce own new id
	$self->{my_sha1} = $new_id;
	$self->{sw_sha1} = _switchsha($self->{my_sha1});
	$self->StartHunting($self->{sw_sha1}, KSTATE_SEARCH_MYSELF);
	
	# ditch old id: make it a normal sha1 and stop it
	$self->SetState($old_sw, KSTATE_PEERSEARCH);
	$self->StopHunting($old_sw);
	
}

########################################################################
# Switch last 2 sha1 things
sub _switchsha {
	my($string) = @_;
	$string = unpack("H*",$string);
	my $new = substr($string,0,-2).substr($string,-1,1).substr($string,-2,1);
	return pack("H*",$new);
}

########################################################################
# Returns hash of given TR
sub tr2hash {
	my($self,$chr) = @_;
	return ($self->{trmap}->{$chr});
}


########################################################################
# Returns X random bytes
sub GetRandomBytes {
	my($self,$numbytes) = @_;
	return join("", map( { pack("H2",int(rand(0xFF))) } (0..$numbytes) ) );
}

sub GetRatingFromArray {
	my($self, @list) = @_;
	my $max_stars = 5;
	if(int(@list) == $max_stars) {
		my($t, $r) = (0, 0);
		for(my $i=0;$i<$max_stars;$i++) {
			$r += abs($list[$i]*$max_stars);
			$t += abs($list[$i]*($i+1));
		}
		return ($t/$r)*$max_stars if $r;
	}
	return undef;
}

########################################################################
# Bootstrap from given ip
sub BootFromPeer {
	my($self,$ref) = @_;
	
	$self->{trustlist}->{$ref->{ip}.":".$ref->{port}}++;
	
	$ref->{cmd} = $self->command_findnode($self->{sw_sha1});
	$self->UdpWrite($ref);
	$self->info("Booting using $ref->{ip}:$ref->{port}");
}


########################################################################
# Assemble Udp-Payload and send it
sub UdpWrite {
	my($self,$r) = @_;
	
	$r->{cmd}->{v} = $self->{ver_str}; # Add implementation details
	my $btcmd = $self->{super}->Tools->BencEncode($r->{cmd});
	my $btlen = length($btcmd);
	
	if($btlen > 1024) {
		$self->warn("Reply would not fit into udp datagram ($btlen bytes). dropping reply");
	}
	else {
		$self->{topclass}->{overloaded} = 1 if ( ($self->{topclass}->{bytes_sent} += $btlen) > MAX_KAD_TRAFFIC );
		$self->{super}->Network->SendUdp($self->{udpsock}, ID=>$self->{topclass}, RemoteIp=>$r->{ip}, Port=>$r->{port}, Data=>$btcmd);
	}
}



########################################################################
# Mark node as killable
sub KillNode {
	my($self,$sha1) = @_;
	$self->panic("Invalid SHA: $sha1") unless $self->ExistsNodeHash($sha1);
	$self->{_killnode}->{$sha1}++;
}

########################################################################
# Add a node to our internal memory-only blacklist
sub BlacklistBadNode {
	my($self,$ref) = @_;
	$self->{super}->Network->BlacklistIp($self->{topclass}, (unpack("H*",$ref->{sha1}).'@'.$ref->{ip}), 300);
	return undef;
}

########################################################################
# Check if a node is blacklisted
sub NodeIsBlacklisted {
	my($self,$ref) = @_;
	return $self->{super}->Network->IpIsBlacklisted($self->{topclass}, (unpack("H*",$ref->{sha1}).'@'.$ref->{ip}));
}


########################################################################
# Return commands to announce ourself
sub ReAnnounceOurself {
	my($self,$sha) = @_;
	$self->panic("Invalid SHA: $sha") unless defined($self->{huntlist}->{$sha});
	my $NEAR = $self->GetNearestNodes($sha,K_BUCKETSIZE,1);
	my $count = 0;
	foreach my $r (@$NEAR) {
		$self->panic if length($r->{token}) == 0; # remove me - (too paranoid : fixme :)
		$self->debug("Announcing to $r->{ip} $r->{port}  ($r->{good})");
		my $cmd = {ip=>$r->{ip}, port=>$r->{port}, cmd=>$self->command_announce($sha,$r->{token})};
		$self->UdpWrite($cmd);
		$count++;
	}
	return $count;
}

########################################################################
# Return the rating set by user
sub GetLocalRating {
	my($self, $rate_sha) = @_;
	my $vref = $self->{votelist}->{$rate_sha} or $self->panic("sha not in votelist!");
	my $tsha = unpack("H40", $vref->{info_hash});
	my $rate = 0;
	if(my $so = $self->{super}->Storage->OpenStorage($tsha)) {
		$rate = $so->GetLocalRating;
	}
	return $rate;
}

########################################################################
# Updates cached value of dht-rating
sub UpdateRemoteRating {
	my($self, $rate_sha, $stars) = @_;
	
	my $vref = $self->{votelist}->{$rate_sha} or $self->panic("sha not in votelist!");
	my $tsha = unpack("H40", $vref->{info_hash});
	if(my $so = $self->{super}->Storage->OpenStorage($tsha)) {
		$so->UpdateRemoteRating($stars);
	}
}

########################################################################
# Send vote RPCs to good known peers
sub QueryVotes {
	my($self, $sha) = @_;
	my $NEAR   = $self->GetNearestNodes($sha,int(1.3*K_BUCKETSIZE),1); # we announce to a slightly larger bucket as
	my $rating = $self->GetLocalRating($sha);                          # ..votes are not supported by all clients
	my $count  = 0;
	foreach my $r (@$NEAR) {
		$self->debug("VoteQuery to $r->{ip} $r->{port}  ($r->{good})");
		my $cmd = {ip=>$r->{ip}, port=>$r->{port}, cmd=>$self->command_vote_query($sha,$r->{token},$rating)};
		$self->UdpWrite($cmd);
		$count++;
	}
	return $count;
}

########################################################################
# Returns the $nodenum nearest nodes
sub GetNearestNodes {
	my($self,$sha,$nodenum,$need_tokens) = @_;
	$self->panic("Invalid SHA: $sha") unless defined($self->{huntlist}->{$sha});
	$nodenum ||= K_BUCKETSIZE;
	my @BREF = ();
	
	for(my $i=$self->{huntlist}->{$sha}->{bestbuck}; $i >= 0; $i--) {
		next unless defined($self->{huntlist}->{$sha}->{buckets}->{$i}); # Empty bucket
		foreach my $buckref (@{$self->{huntlist}->{$sha}->{buckets}->{$i}}) { # Fixme: We shall XorSort them!
			next if $need_tokens && ($buckref->{good} == 0 || length($buckref->{token}) == 0);
			push(@BREF,$buckref);
			if(--$nodenum < 1) { $i = -1 ; last; }
		}
	}
	return \@BREF;
}



sub GetNearestGoodFromSelfBuck {
	my($self,$target) = @_;
	
	my @R       = ();
	my $nodenum = K_BUCKETSIZE;
	my $sha = $self->{sw_sha1};
	
	for(my $i = (_GetBucketIndexOf($sha,$target)+1); $i >=0; $i--) {
		next unless defined($self->{huntlist}->{$sha}->{buckets}->{$i});
		foreach my $buckref (@{$self->{huntlist}->{$sha}->{buckets}->{$i}}) {
			next if $buckref->{good} == 0;
			push(@R, $buckref);
			goto RETURN_GOODNODES if --$nodenum < 1;
		}
	}
	RETURN_GOODNODES:
	return \@R;
}





# Return concated nearbuck list
sub GetConcatedNGFSB {
	my($self,$target) = @_;
	my $aref = $self->GetNearestGoodFromSelfBuck($target);
	return join('', map( $self->_encodeNode($_), @$aref) );
}

# Ping nodes and kick dead peers
sub AliveHunter {
	my($self) = @_;
	my $NOWTIME = $self->{super}->Network->GetTime;
	if($self->{xping}->{trigger} < $NOWTIME-(K_ALIVEHUNT)) {
		$self->{xping}->{trigger} = $NOWTIME;
		
		my $used_slots = scalar(keys(%{$self->{xping}->{list}}));
		my $good_ping  = 1; # how many 'good' nodes we are going to ping anyway
		
		while ( $used_slots < K_ALIVEHUNT && (my $r = pop(@{$self->{xping}->{cache}})) ) {
			next unless $self->ExistsNodeHash($r->{sha1}); # node vanished
			if( !exists($self->{xping}->{list}->{$r->{sha1}}) and ( !$r->{good} or ($r->{lastseen}+300 < $NOWTIME) or ($r->{good} && ($r->{rfail} || $good_ping-- > 0)) ) ) {
				$self->{xping}->{list}->{$r->{sha1}} = 0; # No reference; copy it!
				$used_slots++;
			}
		}
		
		if(scalar(@{$self->{xping}->{cache}}) == 0) {
			# Refresh cache
			$self->debug("Refilling cache with fresh nodes");
			@{$self->{xping}->{cache}} = List::Util::shuffle(values(%{$self->{_addnode}->{hashes}}));
		}
		
		foreach my $sha1 (keys(%{$self->{xping}->{list}})) {
			unless($self->ExistsNodeHash($sha1)) {
				delete $self->{xping}->{list}->{$sha1}; # Node vanished
			}
			else {
				if($self->{xping}->{list}->{$sha1} == 0) { # not pinged yet
					$self->{xping}->{list}->{$sha1}++; # if this node is good, ->SetNodeAs good will remove it before we have time to punish the node
				}
				elsif( $self->PunishNode($sha1) ) {
					next; # -> Node got killed. Do not ping it
				}
				my $cmd = $self->command_ping($self->{sw_sha1});
				my $nref= $self->GetNodeFromHash($sha1);
				$self->UdpWrite({ip=>$nref->{ip}, port=>$nref->{port},cmd=>$cmd});
			}
		}
	}
}

########################################################################
# Increase rfail and kill node if it appears to be dead
sub PunishNode {
	my($self,$sha) = @_;
	my $nref = $self->GetNodeFromHash($sha);
	$nref->{rfail} += 2;
	if( $nref->{rfail} >= K_MAX_FAILS ) {
		$self->KillNode($sha);
		$self->BlacklistBadNode($nref);
		return 1;
	}
	return 0;
}

########################################################################
# Rotate top-secret token
sub RotateToken {
	my($self) = @_;
	$self->{my_token_2} = $self->{my_token_1};
	$self->{my_token_1} = $self->GetRandomBytes(TOKEN_SIZE) or $self->panic("No random numbers");
}

########################################################################
# Returns TRUE if given token is ok
sub TokenIsValid {
	my($self,$token) = @_;
	return 1 if $token eq $self->{my_token_1};
	return 2 if $token eq $self->{my_token_2};
	return 0;
}

########################################################################
# Remove stale memlist entries
sub MemlistCleaner {
	my($self, $memlist) = @_;
	my $deadline = $self->{super}->Network->GetTime-(K_REANNOUNCE);
	foreach my $this_sha1 (keys(%{$memlist})) {
		my $peers_left = 0;
		while(my($this_pid, $this_ref) = each(%{$memlist->{$this_sha1}})) {
			if($this_ref->{_seen} < $deadline) {
				delete($memlist->{$this_sha1}->{$this_pid});
			}
			else {
				$peers_left++;
			}
		}
		delete($memlist->{$this_sha1}) if $peers_left == 0; # Drop the sha itself
	}
}


########################################################################
# Adds a new item to given memlist
sub MemlistAddItem {
	my($self, $mlist, $info_hash, $id, $values) = @_;
	
	$mlist->{$info_hash}->{$id}          = $values;
	$mlist->{$info_hash}->{$id}->{_seen} = $self->{super}->Network->GetTime;
	
	my $add_ok = 0;
	if(scalar(keys(%$mlist)) > MAX_TRACKED_HASHES) {
		$self->debug("memlist: rollback: too mand ids");
		delete($mlist->{$info_hash});
	}
	elsif(scalar(keys(%{$mlist->{$info_hash}})) > MAX_TRACKED_PEERS) {
		$self->debug("memlist: rollback: too many items in id");
		delete($mlist->{$info_hash}->{$id});
	}
	else {
		$add_ok = 1;
	}
	
	return $add_ok;
}


########################################################################
# Requests a LOCK for given $hash using ip-stuff $ref
# Returns '1' if you got a lock
# Returns '-1' if the node was locked
# Returns 0 if you are out of locks
sub GetAlphaLock {
	my($self,$hash,$ref) = @_;
	
	$self->panic("Invalid hash")      if !$self->{huntlist}->{$hash};
	$self->panic("Invalid node hash") if length($ref->{sha1}) != SHALEN;
	my $NOWTIME = $self->{super}->Network->GetTime;
	my $islocked = 0;
	my $isfree   = 0;
	# fixme: loop could use a rewrite and should use LAST
	for my $lockn (1..K_ALPHA) {
		if(!exists($self->{huntlist}->{$hash}->{"lockn_".$lockn})) {
			$isfree = $lockn;
		}
		elsif($self->{huntlist}->{$hash}->{"lockn_".$lockn}->{locktime} <= ($NOWTIME-(K_QUERY_TIMEOUT))) {
			# Remove thisone:
			my $topenalty = $self->{huntlist}->{$hash}->{"lockn_".$lockn}->{sha1} or $self->panic("Lock #$lockn had no sha1");
			delete($self->{huntlist}->{$hash}->{"lockn_".$lockn})                 or $self->panic("Failed to remove lock!");
			$isfree = $lockn;
			
			$self->PunishNode($topenalty) if $self->ExistsNodeHash($topenalty); # node still there
		}
		elsif($self->{huntlist}->{$hash}->{"lockn_".$lockn}->{sha1} eq $ref->{sha1}) {
			$islocked = 1;
		}
	}
	
	if($islocked)  {
		return -1;
	}
	elsif($isfree) {
		$self->{huntlist}->{$hash}->{"lockn_".$isfree}->{sha1} = $ref->{sha1} or $self->panic("Ref has no SHA1");
		$self->{huntlist}->{$hash}->{"lockn_".$isfree}->{locktime} = $NOWTIME;
		return 1;
	}
	else {
		return 0; # No locks free
	}
	
}

########################################################################
# Try to free a lock for given sha1 node
sub FreeSpecificAlphaLock {
	my($self,$lockhash,$peersha) = @_;
	$self->panic("Invalid hash")      if !$self->{huntlist}->{$lockhash};
	$self->panic("Invalid node hash") if length($peersha) != SHALEN;
	for my $lockn (1..K_ALPHA) {
		if(exists($self->{huntlist}->{$lockhash}->{"lockn_".$lockn}) && $self->{huntlist}->{$lockhash}->{"lockn_".$lockn}->{sha1} eq $peersha) {
#			$self->debug("Releasing lock $lockn");
			delete($self->{huntlist}->{$lockhash}->{"lockn_".$lockn});
			return;
		}
	}
}

########################################################################
# Free all locks for given hash
sub ReleaseAllAlphaLocks {
	my($self,$hash) = @_;
	$self->panic("Invalid hash") if !$self->{huntlist}->{$hash};
	for my $lockn (1..K_ALPHA) {
		delete($self->{huntlist}->{$hash}->{"lockn_".$lockn});
	}
	return undef;
}


########################################################################
# Pong node
sub reply_ping {
	my($self,$bt) = @_;
	return { t=>\$bt->{t}, y=>'r', r=>{id=>$self->{my_sha1}} };
}

########################################################################
# Send get_nodes:values result to peer
sub reply_values {
	my($self,$bt,$aref_values) = @_;
	return { t=>\$bt->{t}, y=>'r', r=>{id=>$self->{my_sha1}, token=>$self->{my_token_1}, values=>$aref_values} };
}

########################################################################
# Peer used an invalid token
sub reply_tokenerror {
	my($self,$bt) = @_;
	return { t=>\$bt->{t}, y=>'e', e=>[203, "announce with invalid token"] };
}

########################################################################
# Reply to a vote command
sub reply_vote {
	my($self, $bt, $vref) = @_;
	
	# make sure to have 0..4 even if the caller messed up
	my @vcpy = qw(0 0 0 0);
	map( { $vcpy[$_] = int($vref->[$_]) } (0..4) );
	return { t=>\$bt->{t}, y=>'r', r=>{id=>$self->{my_sha1}, v=>\@vcpy } };
}

########################################################################
# Assemble a ping request
sub command_ping {
	my($self,$ih) = @_;
	my $tr = $self->{huntlist}->{$ih}->{trmap};
	$self->panic("No tr for $ih") unless defined $tr;
	return { t=>\$tr, y=>'q', q=>'ping', a=>{id=>$self->{my_sha1}} };
}

########################################################################
# Assemble an announce request
sub command_announce {
	my($self,$ih,$token) = @_;
	my $tr = $self->{huntlist}->{$ih}->{trmap};
	$self->panic("No tr for $ih") unless defined $tr;
	$self->panic("No token!")     if length($token) == 0;
	return { t=>\$tr, y=>'q', q=>'announce_peer', a=>{id=>$self->{my_sha1}, port=>$self->{tcp_port}, info_hash=>$ih, token=>$token} };
}

########################################################################
# Assemble vote query request
sub command_vote_query {
	my($self,$ih,$token, $vote) = @_;
	my $tr = $self->{huntlist}->{$ih}->{trmap};
	$self->panic("No tr for $ih") unless defined $tr;
	$self->panic("No token!")     if length($token) == 0;
	return  { t=>\$tr, y=>'q', q=>'vote', a=>{id=>$self->{my_sha1}, token=>$token, vote=>$vote, target=>$ih} };
}


########################################################################
# Assemble FindNode request
sub command_findnode {
	my($self,$ih) = @_;
	my $tr = $self->{huntlist}->{$ih}->{trmap};
	$self->panic("No tr for $ih") unless defined $tr;
	return { t=>\$tr, y=>'q', q=>'find_node', a=>{id=>$self->{my_sha1}, target=>$ih, want=>[ $self->GetWantKey ] } };
}

########################################################################
# Assemble GetPeers request
sub command_getpeers {
	my($self,$ih) = @_;
	my $tr = $self->{huntlist}->{$ih}->{trmap};
	$self->panic("No tr for $ih") unless defined $tr;
	return { t=>\$tr, y=>'q', q=>'get_peers', a=>{id=>$self->{my_sha1}, info_hash=>$ih, want=>[ $self->GetWantKey ] } };
}


########################################################################
# Set status of a KNOWN node to 'good'
sub SetNodeAsGood {
	my($self, $ref) = @_;
	
	my $xid = $ref->{hash};
	if($self->ExistsNodeHash($xid)) {
		my $nref = $self->GetNodeFromHash($xid);
		if($nref->{good} == 0) {
			$self->{_addnode}->{badnodes}--;
			$self->{_addnode}->{goodnodes}++;
			$nref->{good} = 1;
		}
		if(defined($ref->{token}) && length($ref->{token})) { # we don't check an upper token-size limit: udp should be 'small enought'
			$nref->{token} = $ref->{token};
		}
		$nref->{lastseen} = $self->{super}->Network->GetTime;
		$nref->{rfail}-- if $nref->{rfail}; # re-gain trust slowly ;-)
	}
	else {
		$self->panic("Unable to set $xid as good because it does NOT exist!");
	}
	delete($self->{xping}->{list}->{$xid}); # No need to ping it again
}

########################################################################
# Add note to routing table
sub AddNode {
	my($self, $ref) = @_;
	my $xid = $ref->{sha1};
	$self->panic("Invalid SHA1: $xid") if length($xid) != SHALEN;
	$self->panic("No port?!")          if !$ref->{port};
	$self->panic("No IP?")             if !$ref->{ip};
	
	my $NOWTIME = $self->{super}->Network->GetTime;
	
	if($xid eq $self->{my_sha1}) {
		$self->debug("AddNode($self,$ref): Not adding myself!");
		return undef;
	}
	elsif($self->NodeIsBlacklisted($ref)) {
		$self->debug("AddNode($self,$ref): Node is blacklisted, not added");
		return undef;
	}
	
	unless($self->ExistsNodeHash($xid)) {
		# This is a new SHA ID
		$self->{_addnode}->{hashes}->{$xid} = { addtime=>$NOWTIME, lastseen=>$NOWTIME, token=>'', rfail=>0, good=>0, sha1=>$xid , qt=>'',
		                                        refcount => 0, ip=>$ref->{ip}, port=>$ref->{port} };
		
		# Insert references to all huntlist items
		foreach my $k (keys(%{$self->{huntlist}})) {
			$self->_inject_node_into_huntbucket($xid,$k);
		}
		
		if($self->{_addnode}->{hashes}->{$xid}->{refcount} == 0) {
			# $self->warn("Insertation rollback: no free buck for thisone!");
			delete($self->{_addnode}->{hashes}->{$xid});
			return undef;
		}
		else {
			# $self->warn("Added new node to routing table");
			$self->{_addnode}->{totalnodes}++;
			$self->{_addnode}->{badnodes}++;
			return 1;
		}
	}
	else {
		# We know this node, only update lastseen
		$self->{_addnode}->{hashes}->{$xid}->{lastseen} = $NOWTIME if !$ref->{norefresh};
		return 0;
	}
}

########################################################################
# Return node reference from sha1-hash
sub GetNodeFromHash {
	my($self,$hash) = @_;
	return ( $self->{_addnode}->{hashes}->{$hash} or $self->panic("GetNodeFromHash would return undef!") );
}

########################################################################
# Returns true if this hash exists.
sub ExistsNodeHash {
	my($self,$hash) = @_;
	return exists($self->{_addnode}->{hashes}->{$hash});
}

########################################################################
# Set Query type to something
sub SetQueryType {
	my($self,$buckref,$what) = @_;
	return $buckref->{qt} = $what;
}

sub GetQueryType {
	my($self,$buckref) = @_;
	return $buckref->{qt};
}

########################################################################
# Returns true if we have not enough nodes
sub MustBootstrap {
	my($self) = @_;
	return ( $self->{_addnode}->{totalnodes} < MIN_KNODES ? 1 : 0 );
}

########################################################################
# Kill nodes added to _killnode
sub RunKillerLoop {
	my($self) = @_;
	foreach my $xkill (keys(%{$self->{_killnode}})) {
		$self->panic("Cannot kill non-existent node") unless $self->ExistsNodeHash($xkill);
		
		my $nk = $self->GetNodeFromHash($xkill);
		my $refcount = $nk->{refcount};
		foreach my $k (keys(%{$self->{huntlist}})) {
			my $bi = int(_GetBucketIndexOf($k,$xkill)); # bucket of this node in this huntlist
			if(ref($self->{huntlist}->{$k}->{buckets}->{$bi}) eq "ARRAY") {
				my $i    = 0;
				my $bs   = undef;
				my $href = $self->{huntlist}->{$k};
				foreach my $noderef (@{$href->{buckets}->{$bi}}) {
					if($noderef->{sha1} eq $xkill) {
						splice(@{$href->{buckets}->{$bi}},$i,1);
						$refcount--;
						$bs = int(@{$href->{buckets}->{$bi}});
						last;
					}
					$i++;
				}
				
				# check if we must fixup bestbuck-entry
				if(defined($bs) && $bs == 0 && $bi == $href->{bestbuck}) {
					delete($href->{buckets}->{$bi});                                                 # Flush empty bucket index
					my $nn = $self->GetNearestNodes($k,1,0);                                         # get a good node
					$href->{bestbuck} = ( int(@$nn) ? _GetBucketIndexOf($k,$nn->[0]->{sha1}) : 0 );  # Fixup bestbuck
				}
			}
		}
		$self->panic("Invalid refcount: $refcount") if $refcount != 0;
		
		# Fixup statistics:
		$self->{_addnode}->{totalnodes}--;
		if($nk->{good}) { $self->{_addnode}->{goodnodes}--; }
		else            { $self->{_addnode}->{badnodes}--; }
		
		# Remove from memory
		delete($self->{_addnode}->{hashes}->{$xkill});
		delete($self->{xping}->{list}->{$xkill});
	}
	$self->{_killnode} = {};
}


########################################################################
# Returns BucketValue of 2 hashes
sub _GetBucketIndexOf {
	my($sha_1, $sha_2) = @_;
	my $b1 = unpack("B*", $sha_1);
	my $b2 = unpack("B*", $sha_2);
	my $bucklen   = length($b1);
	my $bucklen_2 = length($b2);
	Carp::confess("\$bucklen != \$bucklen_2 : $bucklen != $bucklen_2") if $bucklen != $bucklen_2;
	my $i = 0;
	for($i = 0; $i<$bucklen; $i++) {
		last if substr($b1,$i,1) ne substr($b2,$i,1);
	}
	return $i;
}


1;

package Bitflu::SourcesBitTorrentKademlia::IPv6;
	use base 'Bitflu::SourcesBitTorrentKademlia';
	
	sub _decodeIPs {
		my($self,$ax) = @_;
		
		my @ref   = ();
		my @nodes = $self->{super}->Tools->DecodeCompactIpV6(join('',@$ax));
		
		foreach my $chunk (@nodes) {
			push(@ref, {ip=>$chunk->{ip}, port=>$chunk->{port}});
		}
		return \@ref;
	}
	
	sub _encodeNode {
		my($self,$r) = @_;
		my $sha    = $r->{sha1};
		my $ip     = $r->{ip};
		my $port   = $r->{port};
		my @ipv6   = $self->{super}->Network->ExpandIpV6($ip);
		
		my $pkt = join('', map(pack("n",$_),(@ipv6,$port)));
		return $sha.$pkt;
	}
	
	sub _decodeNodes {
		my($self,$buff) = @_;
		my @ref = ();
		my $bufflen = length($buff);
		
		for(my $i=0; $i<$bufflen; $i+=38) {
			my($nodeID) = unpack("a20",substr($buff,$i));
			my $yy = substr($buff,$i+20,18); # Note: passing substr() as the argument to DecodeCompactIpV6 kills perl 5.12?!
			my @sx = $self->{super}->Tools->DecodeCompactIpV6($yy);
			push(@ref, {ip=>$sx[0]->{ip}, port=>$sx[0]->{port}, sha1=>$nodeID});
		}
		return \@ref;
	}
	
	sub GetV4ngfsb {
		my($self,$target) = @_;
		if( my $v4 = $self->{topclass}->{proto}->{4} ) {
			return $v4->GetConcatedNGFSB($target);
		}
		return '';
	}
	
	########################################################################
	# Move nodes6 -> nodes
	sub NormalizeReplyDetails {
		my($self,$ref) = @_;
		delete($ref->{r}->{nodes}); # not allowed in IPv6 kademlia
		$ref->{r}->{nodes} = delete($ref->{r}->{nodes6}) if exists($ref->{r}->{nodes6});
	}
	
	########################################################################
	# Send find_node result to peer
	sub reply_findnode {
		my($self,$bt) = @_;
		
		my $r    = { t=>\$bt->{t}, y=>'r', r=>{id=>$self->{my_sha1}, nodes6=>undef} };;
		my $want = $bt->{a}->{want};
		
		$r->{r}->{nodes}  = $self->GetV4ngfsb($bt->{a}->{target}) if ref($want) eq 'ARRAY' && grep(/^n4$/,@$want);
		$r->{r}->{nodes6} = $self->GetConcatedNGFSB($bt->{a}->{target});
		
		return $r;
	}
	
	########################################################################
	# Send get_nodes:nodes result to peer
	sub reply_getpeers {
		my($self,$bt) = @_;
		
		my $r    = { t=>\$bt->{t}, y=>'r', r=>{id=>$self->{my_sha1}, token=>$self->{my_token_1}, nodes6=>undef} };
		my $want = $bt->{a}->{want};
		
		$r->{r}->{nodes}  = $self->GetV4ngfsb($bt->{a}->{info_hash}) if ref($want) eq 'ARRAY' && grep(/^n4$/,@$want);
		$r->{r}->{nodes6} = $self->GetConcatedNGFSB($bt->{a}->{info_hash});
		
		return $r;
	}
	
	########################################################################
	# Returns an IPv6
	sub Resolve {
		my($self,$host) = @_;
		my $xip = $self->{super}->Network->ResolveByProto($host)->{6}->[0];
		return ($self->{super}->Network->IsNativeIPv6($xip) ? $xip : undef);
	}
	
	sub GetHardcodedBootNodes {
		return ( {ip=>'router.bitflu.org', port=>7088}, {ip=>'p6881.router.bitflu.org', port=>6881} );
	}
	
	sub GetCbId {
		return 'kboot6';
	}
	
	sub GetWantKey {
		return 'n6';
	}
	
	sub debug_ {
		my($self,@args) = @_;
		$self->info(@args);
	}
	
1;

package Bitflu::SourcesBitTorrentKademlia::IPv4;
	use base 'Bitflu::SourcesBitTorrentKademlia';
	use strict;
	
	########################################################################
	# Decode Nodes
	sub _decodeNodes {
		my($self,$buff) = @_;
		my @ref = ();
		my $bufflen = length($buff);
		for(my $i=0; $i<$bufflen; $i+=26) {
			my ($nodeID,$a,$b,$c,$d,$port) = unpack("a20CCCCn",substr($buff,$i,26));
			my $IP                         = "$a.$b.$c.$d";
			push(@ref, {ip=>$IP, port=>$port, sha1=>$nodeID});
		}
		return \@ref;
	}
	
	
	
	########################################################################
	# Creates a single NODES encoded entry
	sub _encodeNode {
		my($self,$r) = @_;
		my $buff   = $r->{sha1};
		my $ip     = $r->{ip};
		my $port   = $r->{port};
		
		my $funny_assert = 0;
		foreach my $cx (split(/\./,$ip)) { $buff .= pack("C",$cx); $funny_assert++; }
		Carp::confess("BUGBUG => $ip") if $funny_assert != 4;
		$buff .= pack("n",$port);
		return $buff;
	}

	########################################################################
	# Decode IPs
	sub _decodeIPs {
		my($self,$ax) = @_;
		
		my @ref   = ();
		my @nodes = $self->{super}->Tools->DecodeCompactIp(join('',@$ax));
		
		foreach my $chunk (@nodes) {
			push(@ref, {ip=>$chunk->{ip}, port=>$chunk->{port}});
		}
		return \@ref;
	}
	
	sub GetV6ngfsb {
		my($self,$target) = @_;
		if( my $v6 = $self->{topclass}->{proto}->{6} ) {
			return $v6->GetConcatedNGFSB($target);
		}
		return '';
	}
	
	sub NormalizeReplyDetails {
		# nothing to do for ipv4
	}
	
	########################################################################
	# Send find_node result to peer
	sub reply_findnode {
		my($self,$bt) = @_;
		
		my $r    = { t=>\$bt->{t}, y=>'r', r=>{id=>$self->{my_sha1}, nodes=>undef} };;
		my $want = $bt->{a}->{want};
		
		$r->{r}->{nodes}  = $self->GetConcatedNGFSB($bt->{a}->{target});
		$r->{r}->{nodes6} = $self->GetV6ngfsb($bt->{a}->{target}) if ref($want) eq 'ARRAY' && grep(/^n6$/,@$want);
		
		return $r;
	}
	
	########################################################################
	# Send get_nodes:nodes result to peer
	sub reply_getpeers {
		my($self,$bt) = @_;
		
		my $r    = { t=>\$bt->{t}, y=>'r', r=>{id=>$self->{my_sha1}, token=>$self->{my_token_1}, nodes=>undef} };
		my $want = $bt->{a}->{want};
		
		$r->{r}->{nodes}  = $self->GetConcatedNGFSB($bt->{a}->{info_hash});
		$r->{r}->{nodes6} = $self->GetV6ngfsb($bt->{a}->{info_hash}) if ref($want) eq 'ARRAY' && grep(/^n6$/,@$want);
		
		return $r;
	}
	
	########################################################################
	# Returns an IPv4
	sub Resolve {
		my($self,$host) = @_;
		my $xip = $self->{super}->Network->ResolveByProto($host)->{4}->[0];
		return ($self->{super}->Network->IsValidIPv4($xip) ? $xip : undef);
	}
	
	sub GetHardcodedBootNodes {
		return ( {ip=>'router.bitflu.org', port=>7088},{ip=>'router.utorrent.com', port=>6881}, {ip=>'router.bittorrent.com', port=>6881},
		         {ip=>'p6881.router.bitflu.org', port=>6881} );
	}
	
	sub GetCbId {
		return 'kboot';
	}
	
	sub GetWantKey {
		return 'n4';
	}
	

1;

