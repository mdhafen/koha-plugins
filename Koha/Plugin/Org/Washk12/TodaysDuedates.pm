package Koha::Plugin::Org::Washk12::TodaysDuedates;

## It's good practive to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Circulation qw(CalcDateDue);
use Koha::Patron::Category;
use Data::Dumper;

## Here we set our plugin version
our $VERSION = "1.0.0";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name   => 'Todays due dates tool',
    author => 'Michael Hafen',
    description => 'This tool plugin displays the effective due dates for today for any patron category and item type with an issue length set.',
    date_authored   => '2023-03-28',
    date_updated    => '2023-03-28',
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

sub install { return 1; }

sub uninstall { return 1; }

sub tool {
    my ( $self, $args ) = @_;
    my $input = $self->{'cgi'};
    my $dbh = C4::Context->dbh;
    my $branch = $input->param('branch') || C4::Context->userenv->{branch};
    $branch = ( C4::Context->only_my_library() ? C4::Context->userenv->{branch} : $branch );
    my %patrons;

    my %rules;

    my $query = '
SELECT rule_name, rule_value, branchcode,
       categorycode, COALESCE(cc.description,"*") AS categoryname,
       itemtype, COALESCE(it.description,"*") AS itemtypename
  FROM circulation_rules
 LEFT JOIN branches USING (branchcode)
 LEFT JOIN categories AS cc USING (categorycode)
 LEFT JOIN itemtypes AS it USING (itemtype)
 WHERE rule_name IN ( "issuelength", "renewalperiod" ) AND branchcode = ?
  ORDER BY categoryname, itemtypename
';
    my $sth = $dbh->prepare($query);
    $sth->execute($branch);
    while ( my $row = $sth->fetchrow_hashref ) {
        my $code = ($row->{branchcode} || '*') .":". ($row->{categorycode} || '*') .":". ($row->{itemtype} || '*');
        my $pat;
        if ( $row->{categorycode} ) {
            unless ( $patrons{$row->{categorycode}} ) {
                my $cat = Koha::Patron::Categories->find( $row->{categorycode} );
                $patrons{$row->{categorycode}} = {
                    categorycode => $row->{categorycode},
                    dateexpiry => $cat->get_expiry_date(),
                }
            }
            $pat = $patrons{$row->{categorycode}};
        }
        else {
            $pat = { categorycode => $row->{categorycode} };
        }

        my $datedue;
        if ( $row->{rule_name} eq 'renewalperiod' ) {
            $datedue = CalcDateDue( '', $row->{itemtype}, $row->{branchcode}, $pat, $row->{rule_name} );
        }
        else {
            $datedue = CalcDateDue( '', $row->{itemtype}, $row->{branchcode}, $pat );
        }
        $rules{$code} = $row unless ($rules{$code});
        $rules{$code}{$row->{rule_name}} = $datedue;
    }

    my $template = $self->get_template( { file => 'TodaysDuedates.tt' } );

    my @rules = map { $rules{$_} } sort keys %rules;
    $template->param(
        branch => $branch,
        rules => \@rules,
    );
    $self->output_html( $template->output() );
}

1;
