#!/usr/bin/perl
# Copyright (c) 2006 Hans Klunder <hans.klunder@bigfoot.com>. All rights reserved.
# Copyright (c) 2009 Dobrica Pavlinusic <dpavlin@rot13.org> All rights reserved.
# Copyright (c) 2012 Hewlett-Packard Development Company, L.P
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

# It's modified by Dobrica Pavlinusic <dpavlin@rot13.org> to include following:
#
# * rewrite LDAP bind request cn: username@domain.com -> uid=username,dc=domain,dc=com
# * rewrite search responses:
# ** expand key:value pairs from hrEduPersonUniqueNumber into hrEduPersonUniqueNumber_key
# ** augment response with yaml/dn.yaml data (for external data import)
#
# Modified by Daniel Higgins <dhiggins@hp.com>
# * fix some socket-reading bugs for large server replies
# * simplify workflow
# * implement dynamic filters support
# * move original bind request and search response filtering to dynamic filters
# * implement addGidNumber dynamic filter

use strict;
use warnings;

use IO::Select;
use IO::Socket;
use IO::Socket::SSL;
use Data::Dump qw/dump/;
use Convert::ASN1 qw(asn_read);
use Net::LDAP::ASN qw(LDAPRequest LDAPResponse);
use fields qw(socket target);
use YAML qw/LoadFile/;
use Carp;
use File::Spec;
use File::Basename;

use lib 'lib';
require ReqCache;
require RRObj;
require ConnectionPair;
require ConnectionList;

our $VERSION = '0.3';
our $sel;            # IO::Select;
our $connectlist;
my $log_fh;

# load config
our %debug ;
our $config ;
loadconfig();

my $cache = new ReqCache(expire => $config->{cacheexpire});

BEGIN
{

    # move to the proper relative directory
    my $SCRIPTDIR = dirname( File::Spec->rel2abs($0) );
    chdir("$SCRIPTDIR/..") || die("cannot chdir: $!");

#    $SIG{__DIE__} = sub { Carp::confess @_ };
#    $SIG{__WARN__} = sub { Carp::cluck @_ };
#    $SIG{'__WARN__'} = sub { warn @_; main::log(@_); };
}

sub loadconfig
{
    my $y      = LoadFile("./etc/config.yaml");
    %debug  = %{ $y->{debug} };
    $config = $y->{config};
    $config->{last}=time();
    #warn "reloading config\n";
}

sub debug
{
    my ($tag,@str)= @_;
    return if ! $debug{lc($tag)};

    my ($package, $filename, $line) = caller;
    print localtime(time)." - $filename:$line - ".uc($tag)." - ".join(" ",@str);
    print "\n";
}
sub log
{
    return unless $config->{log_file};

    if ( !$log_fh )
    {
        open( $log_fh, '>>', $config->{log_file} ) || die "can't open ", $config->{log_file}, ": $!";
        print $log_fh "# " . time;
    }
    $log_fh->autoflush(1);
    print $log_fh localtime()." - ".join( "\n".localtime()." - ", @_ ), "\n";
}

sub handleserverdata
{
    my ($pair) = @_;
    my $clientsocket = $pair->client;
    my $serversocket = $pair->server;

    # read from server
    asn_read( $serversocket, my $respdu );
    if ( !$respdu )
    {
        warn "server closed connection\n" if $debug{net};
        return 0;
    }
    my $response = $LDAPResponse->decode($respdu);
    $respdu = log_response($pair,$response);

    # and send the result to the client
    print $clientsocket $respdu || return 0;

    return 1;    # more expected
}

sub handleclientreq
{
    my $pair= shift;
    my $clientsocket = $pair->client;
    my $serversocket = $pair->server;

    # read from client
    asn_read( $clientsocket, my $reqpdu );
    if ( !$reqpdu )
    {
        warn "client closed connection\n" if $debug{net};
        $connectlist->disconnectPair($pair);
        return undef;
    }
    my $decodedpdu = $LDAPRequest->decode($reqpdu);

    if ( $debug{pkt} )
    {
        debug("pkt", "Packet dump from ".$pair->clientid);
        print '-' x 80, "\n";
        print "Request ASN 1:\n";
        Convert::ASN1::asn_hexdump( \*STDOUT, $reqpdu );
        print "Request Perl:\n";
        print dump($decodedpdu);
        print "\n";
    }

    if ( $decodedpdu->{extendedReq} && $decodedpdu->{extendedReq}->{requestName} eq '1.3.6.1.4.1.1466.20037' )
        {
        # this is an SSL request. not implemented yet
        #TODO
        $connectlist->disconnectPair($pair);
        warn("CRIT: SSL/TLS request but this feature is not implemented");
        return;
        }

    if ( $decodedpdu->{unbindRequest} && $decodedpdu->{unbindRequest} == 1)
    {
        debug("net","Client requested unbind (disconnect) ".$pair->clientid);
        $connectlist->disconnectPair($pair);
        return undef;
    }
    $decodedpdu = log_request($clientsocket,$serversocket,$decodedpdu);


    # check the cache for this request. forward to server if it's not found, or to client if it is
    my $key;
    my $cdata; 
    # only search requests are allowed to be cached
    # to verify: i believe that a bindrequest include a blank searchRequest 
    my $decodedrequest= $decodedpdu->{searchRequest};
    if ($decodedrequest && ! $decodedpdu->{bindRequest} )
	{
    	( $key, $cdata ) = $cache->get( $decodedrequest );

        if ( !$cdata || !$cdata->iscompleted())
        {
            debug("cache","Request $key not cached");
    
            # store the messageid so that we can cache the response later
            # this is a client request, we always need to store this id
            $pair->{clientmsgid} = $key;
            $pair->{request} = $decodedrequest;
            
            # do not make a new cached object of the cache simply isnt completed
            if (!$cdata)
            {
            # no cache entry, make a new one and cache it right away                                                                       
            debug("cache","New cache object created");
            $cdata = new RRObj();
            $cdata->source($clientsocket."-".$decodedpdu->{messageID});
            $cdata->request($decodedrequest);
            $cache->set( $decodedrequest, $cdata );        
            }
        
            # send to server
            debug("cache2","Request not cached",dump(  $key, $decodedpdu->{messageID} )) ;
            my $eres= $LDAPRequest->encode($decodedpdu);
            return $eres;
        }
        else
        {
            debug("cache","Request IS cached");

            # return the cached response, but replace the messageID since it's obviously outdated now
            foreach my $response (@{$cdata->response()})
            {
                 $response->{messageID} = $decodedpdu->{messageID};
                 debug("cache","MSGID:" . $decodedpdu->{messageID} . " key: $key");
                 debug("cache",dump( "pkt", $decodedpdu, $response ));
                 print $clientsocket $LDAPResponse->encode($response);
            }
            return undef;  # return undef to indicate no more work is needed on this job because we could serve everything from cache
        }
    }
    # always send bind requests to server
    # and other requests
#   	if (! $decodedpdu->{bindRequest})
#    {
        debug("cache","Received uncachable bind request from ".$pair->clientid);
        debug("cache2", dump($key, $decodedpdu->{messageID} )) ;
        my $eres= $LDAPRequest->encode($decodedpdu);
        return $eres;
#    }

}

sub log_request
{
    my $clientsocket = shift;
    my $serversocket = shift;
    my $request = shift;

    die "empty pdu" unless $request;

    #	print '-' x 80,"\n";
    #	print "Request ASN 1:\n";
    #	Convert::ASN1::asn_hexdump(\*STDOUT,$pdu);
    #	print "Request Perl:\n";

    warn "## Received request" if $debug{net};
    warn "Request: " . dump($request) if $debug{pktsecure};

    # do dynamic filters
    foreach my $filter ( @{ $config->{infilters} } )
    {
        warn( "running filter: " . $filter ) if $debug{filter};

        eval {
            my $filterobj = new $filter;
            $filterobj->filter($request);
        };
        if ($@)
        {
            warn "Unable to run filter $filter: $@" if $debug{filter};
        }

	if ( $config->{filtervalidate} == 1 )
		{
		my $req= $LDAPRequest->encode($request);
			if (! defined($req))
				{
				die("ERROR: after running filter $filter, the request does not compile anymore! this probably means the filter corrupted the data structure!");
			
				}
		}
    }

    return $request;
}

sub load_filters
{
    my ( $dir, $store ) = @_;

    opendir( my $dh, "$dir" );
    foreach my $file ( grep /^([^\.]+)\.pm$/, readdir $dh )
    {
        $file =~ m/^([^\.]+)\.pm$/;
        my $filter = $1;
        warn( "load filter: " . $filter ) if $debug{filter};
        eval { require "$dir/$file"; };

        if ($@)
        {
            warn "Unable to load $file: $@" if $debug{filter};
        }
        else
        {
            push @$store, $filter;
        }

    }
    closedir($dh);
}

sub log_response
{
    my $pair = shift;
    my $clientsocket = $pair->client;
    my $serversocket = $pair->server;
    my $response = shift;
    die "empty pdu" unless $response;

    #	print '-' x 80,"\n";
    #	print "Response ASN 1:\n";
    #	Convert::ASN1::asn_hexdump(\*STDOUT,$pdu);
    #	print "Response Perl:\n";
    debug("pkt","Response: " . dump($response)); 

    if ( defined $response->{protocolOp}->{searchResEntry} )
    {
        my $uid = $response->{protocolOp}->{searchResEntry}->{objectName};
        debug("filter","Filter on objectName $uid");

        # searchResEntry has format { attributes => [ { type => ATTRNAME, vals => [actual values] } , ... ], objectName => 'DN' }

        # do dynamic filters
        foreach my $filter ( @{ $config->{outfilters} } )
        {
            debug("filter","Running filter: " . $filter ); 

            eval {
                my $filterobj = new $filter;
                my $res       = $filterobj->filter( $response->{protocolOp}->{searchResEntry} );
            };
            if ($@)
            {
                debug("filter","Unable to run filter $filter: $@");
            }
	if ( $config->{filtervalidate} == 1 )
		{
		my $eres= $LDAPResponse->encode($response);
			if (! defined($eres))
				{
				die("WARNING: after running filter $filter, the response does not compile anymore!");
				}
		}
        }

        # do YAML attributes
        # YAML file may be a DN-named file or attributename/value ending in .yaml
        # ie gidNumber/3213.yaml
        my @additional_yamls = ($uid);
        foreach my $attr ( @{ $response->{protocolOp}->{searchResEntry}->{attributes} } )
        {
            foreach my $v ( @{ $attr->{vals} } )
            {
                push @additional_yamls, $attr->{type} . '/' . $v;
            }
        }

        #warn "# additional_yamls ",dump( @additional_yamls );
        foreach my $path (@additional_yamls)
        {
            my $full_path = $config->{yaml_dir} . '/' . $path . '.yaml';
            next unless -e $full_path;

            my $data = LoadFile($full_path);
            debug("filter","YAML: $full_path yaml = ", dump($data)); 

            foreach my $type ( keys %$data )
            {
                my $vals = $data->{$type};

                push @{ $response->{protocolOp}->{searchResEntry}->{attributes} },
                  {
                    type => $config->{overlay_prefix} . $type,
                    vals => ref($vals) eq 'ARRAY' ? $vals : [$vals],
                  };
            }
        }

    }
    ##cache storage
    if ( $_ = $pair->{clientmsgid} )
    {
        warn "CACHE: Previous request: $_" if $debug{cache};
        warn dump($response) if $debug{cache2};
        my $cached = $cache->get($_);
        # obj not in cache, create a new one and cache that. otherwise append to it:
        # responses might be more than one element
        if (! $cached)
        {
            my $cached= new RRObj();
        }

        if ( $response->{protocolOp}->{searchResDone})
        {
                $cached->iscompleted(1);
        } 
        $cached->response($response);
        $cache->set( $_, $cached );
    }
    else
    {

        #            warn "CACHE: no previous request for $response->{messageID}";
    }
    ##
    my $pdu = $LDAPResponse->encode($response);

    #    warn "## response = ", dump($response);

    return $pdu;
}

sub connect_to_server
{
    my $sock;
    if ( $config->{upstream_ssl} )
    {
        $sock = IO::Socket::SSL->new( $config->{upstream_ldap} . ':ldaps' );
    }
    else
    {
        $sock = IO::Socket::INET->new(
            Proto    => 'tcp',
            PeerAddr => $config->{upstream_ldap},
            PeerPort => 389,
        );
    }

    if ( !$sock )
    {
        warn "can't open ", $config->{upstream_ldap}, " $!\n" if $debug{net};
        return undef;
    }

    warn "## connected to ", $sock->peerhost, ":", $sock->peerport, "\n" if $debug{net};
    return $sock;
}

sub handleClientConnection
{
    my $sel = shift;    # IO::Selector
    my $pair= shift;    # pair

    my $clientreq = handleclientreq( $pair );
    if ( !defined($clientreq) )
    {
        # handleclientreq returned undef, meaning it handled all the work itself
        return 1;
    }

    # we have data to proxy, connect to the server now. 
    # if we don't already have a socket connection
    my $srv = $pair->server;
    if ( !$srv )
     {
     $srv= connect_to_server;
     $connectlist->newServer($pair,$srv);
     # server failed to connect. disconnect all
     if ( !$pair->server )
         {
             $connectlist->disconnectPair($pair);
             return 0;
         }
    
     }
    # and send the data
    print $srv $clientreq;
    debug("net","Sent client request to server: ".$pair->clientid);

    return 1;
}


sub clientState()
{
        my ($pair) =@_;


        # waiting for request
        # parsing request
        #
}


#MAIN


if ( !-d $config->{yaml_dir} )
{
    warn "DISABLE ", $config->{yaml_dir}, " data overlay" if $debug{warn};
}

my $listenersock = IO::Socket::INET->new(
    Listen    => 5,
    Proto     => 'tcp',
    Reuse     => 1,
    LocalAddr => $config->{listen},
) || die "can't open listen socket: $!";

$sel                  = IO::Select->new($listenersock);
$config->{outfilters} = [];
$config->{infilters}  = [];
load_filters( $config->{outfilter_dir}, $config->{outfilters} );
load_filters( $config->{infilter_dir},  $config->{infilters} );
warn "# config = ", dump($config);

$connectlist= new ConnectionList("sel" => $sel);

while ( my @ready = $sel->can_read )
{ 
    if ($config->{last}+15<= time())
	{
    	# reload config every 15 seconds, subject to connections being made
    	# this allows changing log levels on the fly
    	loadconfig();
	}
    if ( ! $connectlist->serverBusy() )
	{
        # purge the cache (garbage collect) when the server is idle
        $cache->purge();
	}


    debug("net","Select() polling");# if $debug{net};
    foreach my $fh (@ready)
    {
        debug("net","Connection ready ". ConnectionList::_endp($fh));# if $debug{net};
        if ( $fh == $listenersock )
        {

            # listener is ready, meaning we have a new connection req waiting

            # accept
            my $psock = $listenersock->accept;
            # and store
            my $endp= $connectlist->newClient($psock);
            debug("net","Accepted new client: $endp");
        }
        elsif ( $connectlist->isClient($fh) )
        {
            my $pair= $connectlist->findPair($fh);

            # a client socket is ready, a request has come in on it
            handleClientConnection($sel,$pair);
            debug("net","Received client request (data) ".$pair->clientid);
        }
        elsif ( $connectlist->isServer($fh))
        {
            my $pair= $connectlist->findPair($fh);
            debug("net","Server replied with data ".$pair->serverid()." -> ".$pair->clientid());
            if ( !handleserverdata($pair))
            {
                $connectlist->disconnectPair($pair);
            }
        }
        else
        {
            warn "BUG: Packet is from Neither client nor associated server. who are you? ".ConnectionList::_endp($fh)." \n";
            print "->".$connectlist->isClient($fh)." ".$connectlist->isServer($fh);
            print "\n";
            print "->".dump($connectlist->findPair($fh));
            print "\n";
        }

    }
}


1;
