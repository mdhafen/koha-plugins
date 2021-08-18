package Koha::Plugin::Org::Washk12::USMarcHoldingsImporter;

## It's good practive to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use MARC::Batch;
use MARC::Record;
use C4::Context;

## Here we set our plugin version
our $VERSION = "1.0.2";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name   => 'USMARC Holdings Importer',
    author => 'Michael Hafen',
    description => 'This plugin creates Koha compatible MARC records from USMARC records with 852 holdings.',
    date_authored   => '2021-05-06',
    date_updated    => '2021-08-17',
    minimum_version => undef,
    maximum_version => undef,
    version         => $VERSION,
};

## This is the minimum code required for a plugin's 'new' method
## More can be added, but none should be removed
sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub uninstall { return 1; }

## The existiance of a 'to_marc' subroutine means the plugin is capable
## of converting some type of file to MARC for use from the stage records
## for import tool
##
## For this I cross-referenced the default MARC structure in Koha
## comparing the 852 USMARC subfields to the 952 Koha item subfields 
## 
sub to_marc {
    my ( $self, $args ) = @_;

    my $data = $args->{data};
    open( my $DATA, '<', \$data );    # Mock a file handle

    my $batch = MARC::Batch->new( 'USMARC', $DATA );
    my $modified_batch = q{};

    while ( my $record = $batch->next() ) {
        my @field_852 = $record->field('852');

        foreach my $field_852 (@field_852) {
            my ( $homeb, $holdb, $call, $price ) = ('','','',0);
            my ( $bar, $notes, $urls, $type ) = ('','','','');
            my @fields;
            $homeb = $field_852->subfield('a') || C4::Context->userenv->{'branch'};
            $holdb = $field_852->subfield('b') || C4::Context->userenv->{'branch'};
            $call = join(q{ }, $field_852->subfield('k'), $field_852->subfield('h'), $field_852->subfield('i'), $field_852->subfield('m') ) || $record->subfield('090','a');
            $price = $field_852->subfield('9') || $field_852->subfield('r');
            $price =~ s/[^\d\.]//g;
            $bar = $field_852->subfield('p');
            $notes = join('|',$field_852->subfield('z'));
            $urls = join('|',$field_852->subfield('u'));
            $type = $record->subfield('942','c');

            # validate branchcode for home and holding branch
            my $libraries_filter = {};
            if ( C4::Context->only_my_library() ) {
                $libraries_filter->{'branchcode'} = C4::Context->userenv->{'branch'};
            }
            my $libraries = Koha::Libraries->search($libraries_filter)->unblessed;
            unless ( $homeb && grep { $_->{'branchcode'} eq $homeb } @$libraries ) {
                $homeb = C4::Context->userenv->{'branch'} || undef;
            }
            unless ( $holdb && grep { $_->{'branchcode'} eq $holdb } @$libraries ) {
                $holdb = C4::Context->userenv->{'branch'} || undef;
            }

            # validate item type
            my $itemtypes = Koha::ItemTypes->search_with_localization($libraries_filter)->unblessed;
            unless ( $type && grep { $_->{'itemtype'} eq $type } @$itemtypes ) {
                $type = undef;
            }
            # Don't validate barcode being unique, that is already handled

            push( @fields, 'a' => $homeb ) if ( $homeb );
            push( @fields, 'b' => $holdb ) if ( $holdb );
            push( @fields, 'o' => $call ) if ( $call );
            push( @fields, 'g' => $price ) if ( $price );
            push( @fields, 'v' => $price ) if ( $price );
            push( @fields, 'p' => $bar ) if ( $bar );
            push( @fields, 'z' => $notes ) if ( $notes );
            push( @fields, 'u' => $urls ) if ( $urls );
            push( @fields, 'y' => $type ) if ( $type );
            push( @fields, '2' => $field_852->subfield('2') ) if ( $field_852->subfield('2') );
            push( @fields, '3' => $field_852->subfield('3') ) if ( $field_852->subfield('3') );
            push( @fields, 'c' => $field_852->subfield('c') ) if ( $field_852->subfield('c') );
            push( @fields, 'f' => $field_852->subfield('f') ) if ( $field_852->subfield('f') );
            push( @fields, 'j' => $field_852->subfield('j') ) if ( $field_852->subfield('j') );
            push( @fields, 't' => $field_852->subfield('t') ) if ( $field_852->subfield('t') );

            my $field_952 = MARC::Field->new(
                952, $field_852->indicator(1), $field_852->indicator(2),
                @fields
            );

            $record->append_fields($field_952);
        }

        $record->delete_fields(@field_852);

        $modified_batch .= $record->as_usmarc() . "\x1D";
    }

    return $modified_batch;
}

1;
