package Koha::Plugin::Org::Washk12::MassMessageTool;

## It's good practive to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use Koha::Notice::Templates;
use Koha::Patron;
use Koha::Library;

## Here we set our plugin version
our $VERSION = "1.1.3";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name   => 'Mass Message Tool',
    author => 'Michael Hafen',
    description => 'This tool plugin sends messages to patrons en-mass',
    date_authored   => '2021-08-09',
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
    my $step = $input->param('do_it') || 0;
    unless ( $step ) {
        $self->show_options();
    }
    elsif ( $step eq '1' ) {
        $self->get_patrons();
    }
    elsif ( $step eq '2' ) {
        $self->send_messages();
    }
    else {
        print $input->redirect('/cgi-bin/koha/tools/tools-home.pl');
    }
}

sub show_options {
    my ( $self, $args ) = @_;

    my $input = $self->{'cgi'};
    my $dbh = C4::Context->dbh;
    my $template = $self->get_template( { file => 'options.tt' } );
    $template->param( step => 1 );
    my $branch = ( C4::Context->only_my_library() ? C4::Context->userenv->{branch} : undef );
    my %letters = (
        'circ' => { 'default' => [], 'specific' => {} },
        'acct' => { 'default' => [], 'specific' => {} },
    );
    my ( $sql, @where, @args, $lets );

    my $sort1;
    $sql = 'SELECT DISTINCTROW sort1 FROM borrowers WHERE sort1 IS NOT NULL AND sort1 <> ""'. ( $branch ? ' AND branchcode = '. $dbh->quote($branch) .' ' : '' ) .' ORDER BY sort1';
    $sort1 = C4::Context->dbh->selectall_arrayref($sql, { Slice => {} });

    my $sort2;
    $sql = 'SELECT DISTINCTROW sort2 FROM borrowers WHERE sort2 IS NOT NULL AND sort2 <> ""'. ( $branch ? ' AND branchcode = '. $dbh->quote($branch) .' ' : '' ) .' ORDER BY sort2';
    $sort2 = C4::Context->dbh->selectall_arrayref($sql, { Slice => {} });

    $sql = 'SELECT branchcode, module, code, name, title, content, branchname
            FROM letter
            LEFT OUTER JOIN branches USING (branchcode)
    ';
    if ( $branch ) {
        push @where, "(branchcode = ? OR branchcode = '')";
        push @args, $branch;
    }
    unless ( C4::Context->preference('TranslateNotices') ) {
        push @where, "lang = 'default'";
    }
    push @where, "module in ('circulation','accounts')";
    push @where, "message_transport_type = 'email'";
    $sql .= " WHERE ".join(" AND ", @where) if @where;
    $sql .= " ORDER BY branchcode, module, code";
    $lets = $dbh->selectall_arrayref($sql, { Slice => {} }, @args);

    foreach my $let ( @$lets ) {
        my $mod = $let->{'module'};
        if ( $let->{'branchcode'} ) {
            my $br = $let->{'branchname'};
            unless ( $letters{$mod}{'specific'}{$br} ) {
                $letters{$mod}{'specific'}{$br} = [];
            }
            push @{ $letters{$mod}{'specific'}{$br} }, $let;
        }
        else {
            push @{ $letters{$mod}{'default'} }, $let;
        }
    }

    my %sql_fields;
    my @tables = ( 'branches', 'borrowers' );
    for my $table ( @tables ) {
        $sql_fields{$table} = [ get_columns_for($table) ];
    }

    # calculated fields
    push @tables, 'calculated';
    $sql_fields{'calculated'} = [
        { value => 'issues.content', text => 'checked out titles' },
        { value => 'items.content', text => 'overdue titles' },
        { value => 'fines.content', text => 'fines' },
    ];

    $template->param(
        sort1 => $sort1,
        sort2 => $sort2,
        letters => \%letters,
        sql_fields => \%sql_fields,
        tables => \@tables,
    );
    $self->output_html( $template->output() );
}

sub get_patrons {
    my ( $self, $args ) = @_;
    my $dbh = C4::Context->dbh;
    my $input = $self->{'cgi'};
    my $template = $self->get_template( { file => 'patrons.tt' } );
    my $branch = $input->param('branch');
    my $category = $input->param('category');
    my $sort1 = $input->param('sort1');
    my $sort2 = $input->param('sort2');
    my $issues = $input->param('issues');  # ''|all|today|overdue
    my $fines = $input->param('fines');  # ''|fines
    my $send_to = $input->param('send_to');  # ''|home|work|both

    $template->param(
        step => 2,
        subject => scalar $input->param('message-subject'),
        body => scalar $input->param('message-content'),
        send_to => scalar $send_to,
        issues => $issues,
    );

    my $email_column = 'email';
    if ( $send_to eq 'work' ) {
        $email_column = 'emailpro AS email';
    }
    elsif ( $send_to eq 'both' ) {
        $email_column = 'CONCAT_WS(",",email,emailpro) AS email';
    }
    else {
    }

    my @borrowers;
    my @wheres;
    my @params;
    my @having;
    my $overdue_select = ', (SELECT COUNT(*) FROM issues WHERE issues.borrowernumber = borrowers.borrowernumber AND TO_DAYS(NOW()) - TO_DAYS(date_due) > 0) AS overdues';
    if ( $issues eq 'today' ) {
        $overdue_select = ', (SELECT COUNT(*) FROM issues WHERE issues.borrowernumber = borrowers.borrowernumber AND TO_DAYS(NOW()) - TO_DAYS(date_due) = 0) AS overdues';
        push @having, 'overdues > 0';
    }
    elsif ( $issues eq 'overdue' ) {
        push @having, 'overdues > 0';
    }
    elsif ( $issues eq 'all' ) {
        $overdue_select = ', (SELECT COUNT(*) FROM issues WHERE issues.borrowernumber = borrowers.borrowernumber) AS overdues';
        push @having, 'overdues > 0';
    }

    my $account_select = ', (SELECT SUM(amountoutstanding) FROM accountlines WHERE accountlines.borrowernumber = borrowers.borrowernumber AND amountoutstanding <> 0) AS account';
    if ( $fines eq 'fines' ) {
        push @having, 'account > 0';
    }

    if ( $branch ) {
        push @wheres, 'borrowers.branchcode = ?';
        push @params, $branch;
    }
    if ( $category ) {
        push @wheres, 'borrowers.categorycode = ?';
        push @params, $category;
    }
    if ( $sort1 ) {
        push @wheres, 'borrowers.sort1 = ?';
        push @params, $sort1;
    }
    if ( $sort2 ) {
        push @wheres, 'borrowers.sort2 = ?';
        push @params, $sort2;
    }

    my $query = "SELECT borrowernumber,surname,firstname,sort1,sort2,description,$email_column $account_select $overdue_select FROM borrowers LEFT JOIN categories USING (categorycode)";
    $query .= ' WHERE '. ( join ' AND ', @wheres ) if (@wheres);
    $query .= ' GROUP BY borrowernumber';
    $query .= ' HAVING '. ( join ' OR ', @having ) if (@having);
    $query .= ' ORDER BY sort2,surname,firstname';
    my $sth = $dbh->prepare( $query );
    $sth->execute( @params );
    while ( my $row = $sth->fetchrow_hashref() ) {
        $row->{'account'} = sprintf( "%.2f", $row->{'account'} || 0 );
        $row->{'overdues'} += 0;
        push @borrowers, $row;
    }

    $template->param( patrons => \@borrowers );
    $self->output_html( $template->output() );
}

sub send_messages {
    my ( $self, $args ) = @_;
    my $dbh = C4::Context->dbh;
    my $input = $self->{'cgi'};
    my $template = $self->get_template( { file => 'results.tt' } );
    $template->param( step => 3 );

    my $sent = 0;
    my $subject = $input->param('subject');
    my $body = $input->param('body');
    my $send_to = $input->param('send_to') || '';  # ''|home|work|both
    my @borrowers = $input->multi_param('borrowers');
    my $admin_address = C4::Context->preference('KohaAdminEmailAddress');
    my %branch_map = map { $_->{branchcode} => $_ } @{ Koha::Libraries->search()->unblessed };
    my $item_content_fields = [ 'date_due', 'title', 'author', 'barcode', 'replacementprice' ];
    my $fine_content_fields = [ 'date', 'amountoutstanding', 'description', 'barcode', 'title'];
    my ( $items_content, $overdue_content, $fines_content );

    my $issues_sth = $dbh->prepare(<<'END_SQL');
SELECT *, TO_DAYS(date_due)-TO_DAYS(NOW()) AS days_to_due
         FROM issues
   CROSS JOIN items USING (itemnumber)
   CROSS JOIN biblio USING (biblionumber)
        WHERE issues.borrowernumber = ?
END_SQL

    my $fines_sth = $dbh->prepare(<<'END_SQL');
SELECT date, amountoutstanding, description, barcode, IF( itemnumber <> 0, CONCAT_WS(' ',biblio.title,biblio.subtitle), '' ) AS title
         FROM accountlines
    LEFT JOIN items USING (itemnumber)
    LEFT JOIN biblio USING (biblionumber)
        WHERE accountlines.borrowernumber = ?
          AND amountoutstanding <> 0
END_SQL

    foreach my $borrowernumber ( @borrowers ) {
        my $patron = Koha::Patrons->find($borrowernumber);
        my $from_address = $branch_map{ $patron->branchcode }{branchemail} || $admin_address;
        my ( $title, $content ) = ( $subject, $body );
        $overdue_content = join( "\t", @$item_content_fields ) ."\n";
        $items_content = join( "\t", @$item_content_fields ) ."\n";
        $fines_content = join( "\t", @$fine_content_fields ) ."\n";

        my $to_address = $patron->email;
        if ( $send_to eq 'work' ) {
            $to_address = $patron->emailpro;
        }
        elsif ( $send_to eq 'both' ) {
            $to_address = join ',', grep( {$_} $patron->email,$patron->emailpro );
        }
        $issues_sth->execute($borrowernumber);
        while ( my $item_info = $issues_sth->fetchrow_hashref() ) {
            my $item_content = C4::Letters::get_item_content( { item => $item_info, item_content_fields => $item_content_fields } );
            if ( $item_info->{'days_to_due'} < 0 ) {
                $overdue_content .= $item_content;
            }
            $items_content .= $item_content;
        }

        $fines_sth->execute($borrowernumber);
        while ( my $fine_info = $fines_sth->fetchrow_hashref() ) {
            $fine_info->{'amountoutstanding'} = sprintf( "%.2f", $fine_info->{'amountoutstanding'} );
            $fines_content .= C4::Letters::get_item_content( { item => $fine_info, item_content_fields => $fine_content_fields } );
        }

        my $substitute = {
            'issues.content' => $items_content,
            'items.content' => $overdue_content,
            'fines.content' => $fines_content,
        };
        my $table_params = {
            borrowers => $borrowernumber,
            branches => $patron->branchcode,
        };

        my $letter = C4::Letters::GetPreparedLetter(
            letter => { title => $title, content => $content },
            tables => $table_params,
            substitute => $substitute,
        );
        C4::Letters::EnqueueLetter({
            letter => $letter,
            borrowernumber => $borrowernumber,
            message_transport_type => 'email',
            from_address => $from_address,
            to_address => $to_address,
        });
        $sent++;
    }

    $template->param( sent => $sent );
    $self->output_html( $template->output() );
}

# next sub copied from /tools/letter.pl and modified
sub get_columns_for {
    my $table = shift;
    my $dbh = C4::Context->dbh;
    my @fields = ();
    my %irrelevant = ('timestamp'=>1);
    my %map = (
        branches => 'Library',
        borrowers => 'Patron',
    );

    return () unless $map{$table};
    my $c = 'Koha::'. $map{$table};
    my $o = $c->new();
    my $columns = $o->_columns();
    for my $column (@$columns) {
        next if $irrelevant{ $column };
        push @fields, {
            value => $table .'.'. $column,
            text  => $table .'.'. $column,
        }
    }
    if ($table eq 'borrowers') {
        my $attribute_types = Koha::Patron::Attribute::Types->search(
            {},
            { order_by => 'code' },
        );
        while ( my $at = $attribute_types->next ) {
            push @fields, {
                value => "borrower-attribute:" . $at->code,
                text  => "attribute:" . $at->code,
            }
        }
    }
    return @fields;
}

1;
