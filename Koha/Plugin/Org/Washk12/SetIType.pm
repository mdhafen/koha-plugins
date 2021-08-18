package Koha::Plugin::Org::Washk12::MassMessageTool;

## It's good practive to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access

## Here we set our plugin version
our $VERSION = "1.0.0";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name   => 'Mass Message Tool',
    author => 'Michael Hafen',
    description => 'This tool plugin sends messages to patrons en-mass',
    date_authored   => '2021-08-09',
    date_updated    => '2021-08-09',
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
    my $step = $input->param('do_it') || 0;
    unless ( $step ) {
        $self->show_options();
    }
    elsif ( $step = '1' ) {
        $self->show_results();
    }
    else {
        print $input->redirect('/cgi-bin/koha/tools/tools-home.pl');
    }
}

sub show_options {
    my ( $self, $args ) = @_;

    my $input = $self->{'cgi'};
    my $template = $self->get_template( { file => 'setitype.tt' } );
    $template->param( step => 1 );

    $self->output_html( $template->output() );
}

sub show_results {
    my ( $self, $args ) = @_;
    my $input = $self->{'cgi'};
    my $dbh = C4::Context->dbh;
    my $template = $self->get_template( { file => 'setitype.tt' } );

    $template->param( step => 2 );

    my (@items,$changed_items,$changed_bibs);
    my ($search,$new_itype,$old_itype,$backport);
    my $branch = $input->param('branch');
    $branch = ( C4::Context->only_my_library('IndependentBranchesHideOtherBranchesItems') ? C4::Context->userenv->{branch} : $branch );
    $search = $input->param('callnumber');
    $new_itype = $input->param('itype');
    $old_itype = $input->param('old_itype') || undef;
    $backport = $input->param('backport') || 0;

    if ( $branch && $search && $new_itype ) {
        my @params = ($branch);
        my $query = '
SELECT itemnumber,biblioitemnumber,biblionumber,itemcallnumber,itemtype
  FROM items
       CROSS JOIN biblioitems USING (biblioitemnumber)
 WHERE homebranch = ? AND ';
        if ( $old_itype ) {
            $query .= 'itype = ?';
            push @params, $old_itype;
        }
        else {
            $query .= '( itype IS NULL OR itype = "" )';
        }
        my $sth = $dbh->prepare($query);
        $sth->execute(@params);
        while ( my $row = $sth->fetchrow_hashref ) {
            next unless ( $row->{'itemcallnumber'} =~ /^$search/i );
            my $item = Koha::Items->find( $row->{'itemnumber'} );
            $item->itype($new_itype)->store;
            $changed_items++;

            if ( $backport && ! $row->{'itemtype'} ) {
                $item->biblioitem->itemtype($new_itype)->store;
                $changed_bibs++;
            }
        }
    }

    $template->param(
        changed_items => $changed_items,
        changed_bibs => $changed_bibs,
    );
    $self->output_html( $template->output() );
}

1;
