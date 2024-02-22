package Koha::Plugin::Org::Washk12::UpdateSignOn;

## It's good practive to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use Koha::Patrons;
use XML::LibXML;
use HTTP::Request::Common;
use LWP::UserAgent;

## Here we set our plugin version
our $VERSION = "0.0.1";

## Plugins parameters here
our $SignOn_url = 'https://signon.washk12.org/';
our $SignOn_client = '';
our $SignOn_secret = '';

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name   => 'Update SignOn',
    author => 'Michael Hafen',
    description => 'This tool plugin uses the SignOn api to update LDAP objects',
    date_authored   => '2024-02-22',
    date_updated    => '2024-02-22',
    minimum_version => 22.1104, ## min because of staff interface redesign
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
    my $template = $self->get_template( { file => 'UpdateSignOn.tt' } );
    unless ( $step ) {
        $template->param( step => 1 );
        $self->output_html( $template->output() );
    }
    elsif ( $step eq '2' ) {
        $template->param( step => 2 );
        my $results = $self->call_signon_api;
        $template->param( results => $results );
        $self->output_html( $template->output() );
    }
    else {
        print $input->redirect('/cgi-bin/koha/tools/tools-home.pl');
    }
}

sub call_signon_api {
    my ( $self, $args ) = @_;

    my $input = $self->{'cgi'};
    my $dbh = C4::Context->dbh;

    my %report = ( errors => [], changed => [], created => 0, moved => 0, password => 0 );

    # Work happens here.
    my $query = $input->param('query');
    my %params = (
        'query' => $query,
        '_client_id' => $SignOn_client,
        '_client_secret' => $SignOn_secret,
    );
    my $qs = join '&', map { defined $params{$_} && $params{$_} ne '' ? $_ . '=' . $params{$_} : () } keys %params;
    my $request = HTTP::Request::Common::POST(
        $SignOn_url .'/api/do_google_sync.php' . '?' . $qs,
    );
    my $ua = LWP::UserAgent->new( agent => "Koha ". $Koha::VERSION );
    my $response = $ua->request($request);
    my $xml = $response->decoded_content;
    if ( $xml ) {
        my $doc = XML::LibXML->load_xml( string => $xml );
        if ( $doc->findvalue('//state') eq 'error' ) {
            foreach my $flag ( $doc->findnodes('//flag') ) {
                push @{$report{'errors'}}, $flag->to_literal();
            }
        }
        else {
            foreach my $attr ( $doc->findnodes('//attribute') ) {
                push @{$report{'changed'}}, $attr->to_literal();
            }
            foreach my $flag ( $doc->findnodes('//flag') ) {
                for ( $flag->to_literal() ) {
                    if    ( $_ eq 'MOVED' )        { $report{'moved'} = 1; }
                    elsif ( $_ eq 'CREATED' )      { $report{'created'} = 1; }
                    elsif ( $_ eq 'PASSWORD_SET' ) { $report{'password'} = 1; }
                }
            }
        }
    }

    return \%report;
}

1;
