package Ocsinventory::Agent::XML::Response::Prolog;

use strict;
use Ocsinventory::Agent::XML::Response;

our @ISA = ('Ocsinventory::Agent::XML::Response');

sub new {
    my ($class, @params) = @_;
    
    my $this = $class->SUPER::new(@params);

    bless ($this, $class);

    $this->saveNextTime();

    return $this;
}

sub isInventoryAsked {
    my $self = shift;

    my $parsedContent = $self->getParsedContent();
    if ($parsedContent && exists ($parsedContent->{RESPONSE}) && $parsedContent->{RESPONSE} =~ /^SEND$/) {
	return 1;
    }

    0
}

sub getOptionInfoByName {
    my ($self, $name) = @_;

    my $parsedContent = $self->getParsedContent();

    return unless ($parsedContent && $parsedContent->{OPTION});
    foreach (@{$parsedContent->{OPTION}}) {
      if ($_->{NAME} && $_->{NAME} =~ /^$name$/i) {
        return $_->{PARAM}[0]
      }
    }
}

sub saveNextTime {
    my ($self, $args) = @_;

    my $logger = $self->{logger};
    my $parsedContent = $self->getParsedContent();

    if (!open NEXT_TIME, ">".$self->{params}->{next_timefile}) {
        $logger->error ("Cannot create the ".$self->{params}->{next_timefile}.": $!");
        return;
    }
    close NEXT_TIME or warn;

    my $serverdelay = $self->{accountconfig}->get('PROLOG_FREQ');
    
    my $changed;
    if ($parsedContent && exists ($parsedContent->{PROLOG_FREQ})) {
        if( $parsedContent->{PROLOG_FREQ} ne $self->{accountconfig}->get("PROLOG_FREQ")){
             $logger->info("PROLOG_FREQ has changed since last process(old=".$self->{accountconfig}->get("PROLOG_FREQ").",new=".$parsedContent->{PROLOG_FREQ}.")");
             $changed = 1;
             $self->{accountconfig}->set("PROLOG_FREQ", $parsedContent->{PROLOG_FREQ});
        }
        else{
            $logger->info("PROLOG_FREQ has not changed since last process");
        }  
    }
    
    my $time;
    if( $changed ){
        $logger->info("Compute file_nexttime with random value");
        $time  = time + int rand(($serverdelay?$serverdelay:$self->{params}->{delaytime})*3600);
    }
    else{
        $time = time + ($serverdelay?$serverdelay:$self->{params}->{delaytime})*3600;
    }
    utime $time,$time,$self->{params}->{next_timefile};
    
    if ($self->{params}->{cron}) {
        $logger->info ("Next inventory after ".localtime($time));
    }
}

1;
