package Koha::Plugin::Org::Washk12::TransferItem;

## It's good practive to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use Koha::Library;
use C4::Circulation qw( barcodedecode );

use List::MoreUtils qw( uniq );

## Here we set our plugin version
our $VERSION = "1.0.4";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name   => 'Item Transfer tool',
    author => 'Michael Hafen',
    description => 'This tool plugin moves items to other libraries',
    date_authored   => '2023-04-14',
    date_updated    => '2025-03-26',
    minimum_version => 25.0501, ## min because of staff interface container wrapper
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

sub install { return 1; }

sub uninstall { return 1; }

sub tool {
    my ( $self, $args ) = @_;
    my $input = $self->{'cgi'};
    my $step = $input->param('step') || 0;
    my $template = $self->get_template( { file => 'TransferItem.tt' } );
    unless ( $step ) {
        $template->param( step => 1 );
        $self->output_html( $template->output() );
    }
    elsif ( $step eq '2' ) {
        $template->param( step => 2 );
        my $results = $self->move_items();
        $template->param( results => $results );
        $self->output_html( $template->output() );
    }
    else {
        print $input->redirect('/cgi-bin/koha/tools/tools-home.pl');
    }
}

sub move_items {
    my ( $self, $args ) = @_;

    my $input = $self->{'cgi'};
    my $dbh = C4::Context->dbh;

    my %report = ( moved => 0, unmoved => [] );

    # Work happens here.
    my $split_chars = C4::Context->preference('BarcodeSeparators');
    my $branch = $input->param('from_branch');
    my $to_branch = $input->param('to_branch');
    my $barcode = $input->param('barcode');
    my @barcodes = grep { /\S/ } split(/[\r\n]+/, scalar $input->param('barcodelist') );
    my $to_barcode = $input->param('to_barcode');

    if ( $barcode ) {
        unshift @barcodes, $barcode;
    }
    @barcodes = ( uniq @barcodes );
    for my $code ( @barcodes ) {
        my $replace = ( $to_barcode && $code eq $barcode && $to_barcode ne $barcode );
        $code = barcodedecode( $code ) if $code;

        my $item_filter = { barcode => $code };
        if ( C4::Context->preference('IndependentBranches') ) {
            $item_filter->{homebranch} = $branch;
        }
        my $item = Koha::Items->find($item_filter);
        unless ( $item && $item->barcode ) {
            push @{$report{'unmoved'}}, {barcode=>$code,reason=>'NOT_FOUND'};
            next;
        }

        if ( C4::Context->preference('IndependentBranches') ) {
            $item_filter = { barcode => ($to_barcode || $code), homebranch => $to_branch };
            my $to_item = Koha::Items->find($item_filter);
            if ( $to_item && $to_item->barcode ) {
                push @{$report{'unmoved'}}, {barcode=>$code,reason=>'DEST_DUPLICATE'};
                next;
            }
        }

        if ( $replace && $to_barcode ) {
            $item->barcode( $to_barcode );
        }

        $item->homebranch( $to_branch );
        $item->holdingbranch( $to_branch );
        $item->store;
        $report{'moved'}++;
    }

    return \%report;
}

1;
