package FusionInventory::Agent::Task::NetDiscovery;

use strict;
use warnings;
use threads;
use threads::shared;
use base 'FusionInventory::Agent::Task';

use constant DEVICE_PER_MESSAGE => 4;

use constant START => 0;
use constant RUN   => 1;
use constant STOP  => 2;
use constant EXIT  => 3;

use English qw(-no_match_vars);
use Net::IP;
use Time::localtime;
use UNIVERSAL::require;
use XML::TreePP;

use FusionInventory::Agent::Tools;
use FusionInventory::Agent::Tools::Network;
use FusionInventory::Agent::Tools::Hardware;
use FusionInventory::Agent::XML::Query;

# needed for perl < 5.10.1 compatbility
if ($threads::shared::VERSION < 1.21) {
    FusionInventory::Agent::Threads->use();
}

our $VERSION = '2.2.0';

sub isEnabled {
    my ($self, $response) = @_;

    if (!$self->{target}->isa('FusionInventory::Agent::Target::Server')) {
        $self->{logger}->debug("NetDiscovery task not compatible with local target");
        return;
    }

    my $options = $response->getOptionsInfoByName('NETDISCOVERY');
    if (!$options) {
        $self->{logger}->debug("NetDiscovery task execution not requested");
        return;
    }

    if (!$options->{RANGEIP}) {
        $self->{logger}->error("no IP range defined");
        return;
    }

    $self->{options} = $options;
    return 1;
}

sub run {
    my ($self, %params) = @_;

    # task-specific client, if needed
    $self->{client} = FusionInventory::Agent::HTTP::Client::OCS->new(
        logger       => $self->{logger},
        user         => $params{user},
        password     => $params{password},
        proxy        => $params{proxy},
        ca_cert_file => $params{ca_cert_file},
        ca_cert_dir  => $params{ca_cert_dir},
        no_ssl_check => $params{no_ssl_check},
    ) if !$self->{client};

    my $options     = $self->{options};
    my $pid         = $options->{PARAM}->[0]->{PID};
    my $max_threads = $options->{PARAM}->[0]->{THREADS_DISCOVERY};
    my $timeout     = $options->{PARAM}->[0]->{TIMEOUT};

    # check discovery methods available
    my ($nmap_parameters, $snmp_credentials);

    if (canRun('nmap')) {
       my ($major, $minor) = getFirstMatch(
           command => 'nmap -V',
           pattern => qr/Nmap version (\d+)\.(\d+)/
       );
       $nmap_parameters = compareVersion($major, $minor, 5, 29) ?
           "-sP -PP --system-dns --max-retries 1 --max-rtt-timeout 1000ms" :
           "-sP --system-dns --max-retries 1 --max-rtt-timeout 1000ms"     ;
    } else {
        $self->{logger}->info(
            "Can't run nmap, nmap detection can't be used"
        );
    }

    Net::NBName->require();
    if ($EVAL_ERROR) {
        $self->{logger}->info(
            "Can't load Net::NBName, netbios can't be used"
        );
    }

    FusionInventory::Agent::SNMP::Live->require();
    if ($EVAL_ERROR) {
        $self->{logger}->info(
            "Can't load FusionInventory::Agent::SNMP::Live, snmp detection " .
            "can't be used"
        );
    } else {
        $snmp_credentials = $self->_getCredentials($options);
    }

    # create the required number of threads, sharing variables
    # for synchronisation
    my @addresses :shared;
    my @results   :shared;
    my @states    :shared;

    # compute blocks list
    my $addresses_count = 0;
    foreach my $range (@{$options->{RANGEIP}}) {
        my $block = Net::IP->new(
            $range->{IPSTART} . '-' . $range->{IPEND}
        );
        if (!$block || $block->{binip} !~ /1/) {
            $self->{logger}->error(
                "IPv4 range not supported by Net::IP: ".
                $range->{IPSTART} . '-' . $range->{IPEND}
            );
            next;
        }
        $range->{block} = $block;
        $addresses_count += $range->{block}->size();
    }

    # no need for more threads than addresses to scan
    if ($max_threads > $addresses_count) {
        $max_threads = $addresses_count;
    }

    $self->{logger}->debug("creating $max_threads discovery threads");
    for (my $i = 0; $i < $max_threads; $i++) {
        $states[$i] = START;

        threads->create(
            '_scanAddresses',
            $self,
            \$states[$i],
            \@addresses,
            \@results,
            $snmp_credentials,
            $nmap_parameters,
            $timeout
        )->detach();
    }

    # set internal state
    $self->{pid} = $pid;

    # send initial message to the server
    $self->_sendStartMessage();

    # set all threads in RUN state
    $self->{logger}->debug("activating discovery threads");
    $_ = RUN foreach @states;

    # proceed each given IP block
    foreach my $range (@{$options->{RANGEIP}}) {
        my $block = $range->{block};
        next unless $block;
        do {
            push @addresses, $block->ip(),
        } while (++$block);
        $self->{logger}->debug(
            "scanning range: $range->{IPSTART}-$range->{IPEND}"
        );

        # send block size to the server
        $self->_sendCountMessage(scalar @addresses);

        # set all threads in RUN state
        $_ = RUN foreach @states;

        # wait for all threads to reach STOP state
        while (any { $_ != STOP } @states) {
            delay(1);

            # send results to the server
            while (my $result = do { lock @results; shift @results; }) {
                $result->{ENTITY} = $range->{ENTITY} if defined($range->{ENTITY});
                my $data = {
                    DEVICE        => [$result],
                    MODULEVERSION => $VERSION,
                    PROCESSNUMBER => $pid,
                };
                $self->_sendMessage($data);
            }
        }
    }

    # set all threads in EXIT state
    $self->{logger}->debug("terminating discovery threads");
    $_ = EXIT foreach @states;
    delay(1);

    # send final message to the server
    $self->_sendStopMessage();

    delete $self->{pid};
}

sub exit {
    my ($self) = @_;

    $self->_sendStopMessage() if $self->{pid};
    $self->SUPER::exit();
}

sub _sendUpdateMessage {
    my ($self) = @_;

    $self->_sendMessage({
        AGENT => {
            END => '1'
        },
        MODULEVERSION => $VERSION,
        PROCESSNUMBER => $self->{pid},
        DICO          => "REQUEST",
    });
}

sub _getCredentials {
    my ($self, $options) = @_;

    my @credentials;

    foreach my $credential (@{$options->{AUTHENTICATION}}) {
        if ($credential->{VERSION} eq '3') {
            # a user name is required
            next unless $credential->{USERNAME};
            # DES support is required
            next unless Crypt::DES->require();
        } else {
            next unless $credential->{COMMUNITY};
        }
        push @credentials, $credential;
    }

    return \@credentials;
}

sub _scanAddresses {
    my ($self, $state, $addresses, $results, $snmp_credentials, $nmap_parameters, $timeout) = @_;

    my $logger = $self->{logger};
    my $id     = threads->tid();

    $logger->debug("[thread $id] creation, PAUSE state");

    # start: wait for state to change
    while ($$state == START) {
        delay(1);
    }

    OUTER: while (1) {
        # run: process available addresses until exhaustion
        $logger->debug("[thread $id] switching to RUN state");

        while (my $address = do { lock @{$addresses}; shift @{$addresses}; }) {

            my $result = $self->_scanAddress(
                ip               => $address,
                timeout          => $timeout,
                nmap_parameters  => $nmap_parameters,
                snmp_credentials => $snmp_credentials,
            );

            if ($result) {
                lock $results;
                push @$results, shared_clone($result);
            }
        }

        # stop: wait for state to change
        $$state = STOP;
        $logger->debug("[thread $id] switching to STOP state");
        while ($$state == STOP) {
            delay(1);
        }

        # exit: exit thread
        last OUTER if $$state == EXIT;
    }

    $logger->debug("[thread $id] deletion");
}

sub _sendMessage {
    my ($self, $content) = @_;

    my $message = FusionInventory::Agent::XML::Query->new(
        deviceid => $self->{deviceid},
        query    => 'NETDISCOVERY',
        content  => $content
    );

    $self->{client}->send(
        url     => $self->{target}->getUrl(),
        message => $message
    );
}

sub _scanAddress {
    my ($self, %params) = @_;

    my $logger = $self->{logger};
    my $id     = threads->tid();
    $logger->debug("[thread $id] scanning $params{ip}:");

    my %device = (
        $params{nmap_parameters} ? $self->_scanAddressByNmap(%params)    : (),
        $INC{'Net/NBName.pm'}    ? $self->_scanAddressByNetbios(%params) : (),
        $INC{'Net/SNMP.pm'}      ? $self->_scanAddressBySNMP(%params)    : ()
    );

    # don't report anything without a minimal amount of information
    return unless
        $device{MAC}          ||
        $device{SNMPHOSTNAME} ||
        $device{DNSHOSTNAME}  ||
        $device{NETBIOSNAME};

    $device{IP} = $params{ip};

    if ($device{MAC}) {
        $device{MAC} =~ tr/A-F/a-f/;
    }

    return \%device;
}

sub _scanAddressByNmap {
    my ($self, %params) = @_;

    my $device = _parseNmap(
        command => "nmap $params{nmap_parameters} $params{ip} -oX -"
    );

    $self->{logger}->debug(
        sprintf "[thread %d] - scanning %s with nmap: %s",
        threads->tid(),
        $params{ip},
        $device ? 'success' : 'no result'
    );

    return $device ? %$device : ();
}

sub _scanAddressByNetbios {
    my ($self, %params) = @_;

    my $nb = Net::NBName->new();

    my $ns = $nb->node_status($params{ip});

    $self->{logger}->debug(
        sprintf "[thread %d] - scanning %s with netbios: %s",
        threads->tid(),
        $params{ip},
        $ns ? 'success' : 'no result'
    );
    return unless $ns;

    my %device;
    foreach my $rr ($ns->names()) {
        my $suffix = $rr->suffix();
        my $G      = $rr->G();
        my $name   = $rr->name();
        if ($suffix == 0 && $G eq 'GROUP') {
            $device{WORKGROUP} = getSanitizedString($name);
        }
        if ($suffix == 3 && $G eq 'UNIQUE') {
            $device{USERSESSION} = getSanitizedString($name);
        }
        if ($suffix == 0 && $G eq 'UNIQUE') {
            $device{NETBIOSNAME} = getSanitizedString($name)
                unless $name =~ /^IS~/;
        }
    }

    $device{MAC} = $ns->mac_address();
    $device{MAC} =~ tr/-/:/;

    return %device;
}

sub _scanAddressBySNMP {
    my ($self, %params) = @_;

    foreach my $credential (@{$params{snmp_credentials}}) {
        my %device = $self->_scanAddressBySNMPReal(
            ip         => $params{ip},
            timeout    => $params{timeout},
            credential => $credential
        );

        # no result means either no host, no response, or invalid credentials
        $self->{logger}->debug(
            sprintf "[thread %d] - scanning %s with SNMP, credentials %d: %s",
            threads->tid(),
            $params{ip},
            $credential->{ID},
            %device ? 'success' : 'no result'
        );

        if (%device) {
            $device{AUTHSNMP} = $credential->{ID};
            return %device;
        }
    }

    return;
}

sub _scanAddressBySNMPReal {
    my ($self, %params) = @_;

    my $snmp;
    eval {
        $snmp = FusionInventory::Agent::SNMP::Live->new(
            version      => $params{credential}->{VERSION},
            hostname     => $params{ip},
            timeout      => $params{timeout} || 1,
            community    => $params{credential}->{COMMUNITY},
            username     => $params{credential}->{USERNAME},
            authpassword => $params{credential}->{AUTHPASSPHRASE},
            authprotocol => $params{credential}->{AUTHPROTOCOL},
            privpassword => $params{credential}->{PRIVPASSPHRASE},
            privprotocol => $params{credential}->{PRIVPROTOCOL},
        );
    };
    # an exception here just means no device,  or wrong credentials
    return if $EVAL_ERROR;

    my $info = getDeviceInfo(
        snmp    => $snmp,
        datadir => $self->{datadir},
        logger  => $self->{logger},
    );
    return unless $info;

    return %$info;
}

sub _parseNmap {
    my (%params) = @_;

    my $handle = getFileHandle(%params);
    return unless $handle;

    local $INPUT_RECORD_SEPARATOR; # Set input to "slurp" mode
    my $tpp  = XML::TreePP->new(force_array => '*');
    my $tree = $tpp->parse(<$handle>);
    close $handle;
    return unless $tree;

    my $result;

    foreach my $host (@{$tree->{nmaprun}[0]{host}}) {
        foreach my $address (@{$host->{address}}) {
            next unless $address->{'-addrtype'} eq 'mac';
            $result->{MAC}           = $address->{'-addr'};
            $result->{NETPORTVENDOR} = $address->{'-vendor'};
            last;
        }
        foreach my $hostname (@{$host->{hostnames}}) {
            my $name = eval {$hostname->{hostname}[0]{'-name'}};
            next unless $name;
            $result->{DNSHOSTNAME} = $name;
        }
    }

    return $result;
}

sub _sendStartMessage {
    my ($self) = @_;

    $self->_sendMessage({
        AGENT => {
            START        => 1,
            AGENTVERSION => $FusionInventory::Agent::VERSION,
        },
        MODULEVERSION => $VERSION,
        PROCESSNUMBER => $self->{pid}
    });
}

sub _sendStopMessage {
    my ($self) = @_;

    $self->_sendMessage({
        AGENT => {
            END => 1,
        },
        MODULEVERSION => $VERSION,
        PROCESSNUMBER => $self->{pid}
    });
}

sub _sendCountMessage {
    my ($self, $pid, $count) = @_;

    $self->_sendMessage({
        AGENT => {
            NBIP => $count
        },
        PROCESSNUMBER => $pid
    });
}

1;

__END__

=head1 NAME

FusionInventory::Agent::Task::NetDiscovery - Net discovery support for FusionInventory Agent

=head1 DESCRIPTION

This tasks scans the network to find connected devices, allowing:

=over

=item *

devices discovery within an IP range, through nmap, NetBios or SNMP

=item *

devices identification, through SNMP

=back

This task requires a GLPI server with FusionInventory plugin.

=head1 AUTHORS

Copyright (C) 2009 David Durieux
Copyright (C) 2010-2012 FusionInventory Team
