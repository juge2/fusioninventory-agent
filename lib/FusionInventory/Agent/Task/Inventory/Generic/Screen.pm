package FusionInventory::Agent::Task::Inventory::Generic::Screen;

use strict;
use warnings;

use English qw(-no_match_vars);
use MIME::Base64;
use UNIVERSAL::require;

use File::Find;
use FusionInventory::Agent::Tools;
use FusionInventory::Agent::Tools::Screen;

sub isEnabled {
    my (%params) = @_;
    return 0 if $params{no_category}->{monitor};
    return 1;
}

sub doInventory {
    my (%params) = @_;

    my $inventory = $params{inventory};
    my $logger    = $params{logger};
    my $datadir   = $params{datadir};

    foreach my $screen (_getScreens(logger => $logger, datadir => $datadir)) {
        $inventory->addEntry(
            section => 'MONITORS',
            entry   => $screen
        );
    }
}

sub _getEdidInfo {
    my (%params) = @_;

    Parse::EDID->require();
    if ($EVAL_ERROR) {
        $params{logger}->debug(
            "Parse::EDID Perl module not available, unable to parse EDID data"
        ) if $params{logger};
        return;
    }

    my $edid = Parse::EDID::parse_edid($params{edid});
    if (my $error = Parse::EDID::check_parsed_edid($edid)) {
        $params{logger}->debug("bad edid: $error") if $params{logger};
        # Don't return if edid is finally partially parsed
        return unless ($edid->{monitor_name} && $edid->{week} &&
            $edid->{year} && $edid->{serial_number});
    }

    my $screen = FusionInventory::Agent::Tools::Screen->new( %params, edid => $edid );

    my $info = {
        CAPTION      => $screen->caption || undef,
        DESCRIPTION  => $screen->week_year_manufacture,
        MANUFACTURER => $screen->manufacturer,
        SERIAL       => $screen->serial
    };

    # Add ALTSERIAL if defined by Screen object
    $info->{ALTSERIAL} = $screen->altserial if $screen->altserial;

    return $info;
}

sub _getScreensFromWindows {
    my (%params) = @_;

    FusionInventory::Agent::Tools::Win32->use();

    my @screens;

    # VideoOutputTechnology table, see ref:
    # - https://msdn.microsoft.com/en-us/library/bb980612(v=vs.85).aspx
    # - https://msdn.microsoft.com/en-us/library/ff546605.aspx
    my %ports = qw(
        -1      Other
         0      VGA
         1      S-Video
         2      Composite
         3      YUV
         4      DVI
         5      HDMI
         6      LVDS
         8      D-Jpn
         9      SDI
        10      DisplayPort
        11      eDisplayPort
        12      UDI
        13      eUDI
        14      SDTV
        15      Miracast
    );

    # Vista and upper, able to get the second screen
    foreach my $object (getWMIObjects(
        moniker    => 'winmgmts:{impersonationLevel=impersonate,authenticationLevel=Pkt}!//./root/wmi',
        class      => 'WMIMonitorConnectionParams',
        properties => [ qw/Active InstanceName VideoOutputTechnology/ ]
    )) {
        next unless $object->{InstanceName};
        next unless $object->{Active};

        $object->{InstanceName} =~ s/_\d+//;
        my $screen = {
            id => $object->{InstanceName}
        };

        if (exists($object->{VideoOutputTechnology})) {
            my $port = $object->{VideoOutputTechnology};
            $screen->{PORT} = $ports{$port}
                if (exists($ports{$port}));
        }

        push @screens, $screen;
    }

    # The generic Win32_DesktopMonitor class, the second screen will be missing
    foreach my $object (getWMIObjects(
        class => 'Win32_DesktopMonitor',
        properties => [ qw/
            Caption MonitorManufacturer MonitorType PNPDeviceID Availability
        / ]
    )) {
        next unless $object->{Availability};
        next unless $object->{PNPDeviceID};
        next unless $object->{Availability} == 3;

        push @screens, {
            id           => $object->{PNPDeviceID},
            NAME         => $object->{Caption},
            TYPE         => $object->{MonitorType},
            MANUFACTURER => $object->{MonitorManufacturer},
            CAPTION      => $object->{Caption}
        };
    }

    foreach my $screen (@screens) {
        next unless $screen->{id};
        $screen->{edid} = getRegistryValue(
            path => "HKEY_LOCAL_MACHINE/SYSTEM/CurrentControlSet/Enum/$screen->{id}/Device Parameters/EDID",
            logger => $params{logger}
        );
        $screen->{edid} =~ s/^\s+$// if $screen->{edid};
        delete $screen->{id};
        $screen->{edid} or delete $screen->{edid};
    }

    return @screens;
}

sub _getScreensFromUnix {
    my (%params) = @_;

    my $logger = $params{logger};
    $logger->debug("retrieving EDID data:");

    if (-d '/sys/devices') {
        my @screens;
        my $wanted = sub {
            return unless $_ eq 'edid';
            return unless -e $File::Find::name;
            my $edid = getAllLines(file => $File::Find::name);
            push @screens, { edid => $edid } if $edid;
        };

        no warnings 'File::Find';
        File::Find::find($wanted, '/sys/devices');

        $logger->debug_result(
            action => 'reading /sys/devices content',
            data   => scalar @screens
        );

        return @screens if @screens;
    } else {
        $logger->debug_result(
            action => 'reading /sys/devices content',
            status => 'directory not available'
        );
    }

    if (canRun('monitor-get-edid-using-vbe')) {
        my $edid = getAllLines(command => 'monitor-get-edid-using-vbe');
        $logger->debug_result(
            action => 'running monitor-get-edid-using-vbe command',
            data   => $edid
        );
        return { edid => $edid } if $edid;
    } else {
        $logger->debug_result(
            action => 'running monitor-get-edid-using-vbe command',
            status => 'command not available'
        );
    }

    if (canRun('monitor-get-edid')) {
        my $edid = getAllLines(command => 'monitor-get-edid');
        $logger->debug_result(
            action => 'running monitor-get-edid command',
            data   => $edid
        );
        return { edid => $edid } if $edid;
    } else {
        $logger->debug_result(
            action => 'running monitor-get-edid command',
            status => 'command not available'
        );
    }

    if (canRun('get-edid')) {
        my $edid;
        foreach (1..5) { # Sometime get-edid return an empty string...
            $edid = getFirstLine(command => 'get-edid');
            last if $edid;
        }
        $logger->debug_result(
            action => 'running get-edid command',
            data   => $edid
        );
        return { edid => $edid } if $edid;
    } else {
        $logger->debug_result(
            action => 'running get-edid command',
            status => 'command not available'
        );
    }

    return;
}

sub _getScreens {
    my (%params) = @_;

    my %screens = ();

    my @screens = $OSNAME eq 'MSWin32' ?
        _getScreensFromWindows(%params) :
        _getScreensFromUnix(%params);

    foreach my $screen (@screens) {
        next unless $screen->{edid};

        my $info = _getEdidInfo(
            edid    => $screen->{edid},
            logger  => $params{logger},
            datadir => $params{datadir},
        );
        if ($info) {
            $screen->{CAPTION}      = $info->{CAPTION};
            $screen->{DESCRIPTION}  = $info->{DESCRIPTION};
            $screen->{MANUFACTURER} = $info->{MANUFACTURER};
            $screen->{SERIAL}       = $info->{SERIAL};
            $screen->{ALTSERIAL}    = $info->{ALTSERIAL} if $info->{ALTSERIAL};
        }

        $screen->{BASE64} = encode_base64($screen->{edid});

        delete $screen->{edid};

        # Add or merge found values
        my $serial = $info->{SERIAL} || $screen->{BASE64};
        if (!exists($screens{$serial})) {
            $screens{$serial} = $screen ;
        } else {
            foreach my $key (keys(%$screen)) {
                if (exists($screens{$serial}->{$key})) {
                    if ($screens{$serial}->{$key} ne $screen->{$key} && $params{logger}) {
                        $params{logger}->warning(
                            "Not merging not coherent $key value for screen associated to $serial serial number"
                        );
                    }
                    next;
                }
                $screens{$serial}->{$key} = $screen->{$key};
            }
        }
    }

    return values(%screens);
}

1;
