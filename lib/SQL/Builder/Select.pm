package SQL::Builder::Select;
use strict;
use warnings;
use utf8;
use SQL::Builder::Part;
use SQL::Builder::Where;
use SQL::Builder::Util;
use SQL::Builder::Condition;
use Class::Accessor::Lite (
    new => 0,
    wo => [qw/limit offset distinct for_update/],
    rw => [qw/prefix/],
);

sub new {
    my $class = shift;
    my %args = @_ == 1 ? %{$_[0]} : @_;
    my $self = bless {
        select             => +[],
        distinct           => 0,
        select_map         => +{},
        select_map_reverse => +{},
        from               => +[],
        joins              => +[],
        index_hint         => +{},
        group_by           => +[],
        order_by           => +[],
        prefix             => 'SELECT ',
        %args
    }, $class;

    return $self;
}

sub new_condition {
    my $self = shift;

    SQL::Builder::Condition->new(
        quote_char => $self->{quote_char},
        name_sep   => $self->{name_sep},
    );
}

sub bind {
    my $self = shift;
    my @bind;
    push @bind, $self->{where}->bind  if $self->{where};
    push @bind, $self->{having}->bind if $self->{having};
    return \@bind;
}

sub add_select {
    my ($self, $term, $col) = @_;

    $col ||= $term;
    push @{ $self->{select} }, $term;
    $self->{select_map}->{$term} = $col;
    $self->{select_map_reverse}->{$col} = $term;
    return $self;
}

sub add_from {
    my ($self, $table, $alias) = @_;
    push @{$self->{from}}, [$table, $alias];
    return $self;
}

sub add_join {
    my ($self, $table, $joins) = @_;

    push @{ $self->{joins} }, {
        table => $table,
        joins => $joins,
    };
    return $self;
}

sub add_index_hint {
    my ($self, $table, $hint) = @_;

    $self->{index_hint}->{$table} = {
        type => $hint->{type} || 'USE',
        list => ref($hint->{list}) eq 'ARRAY' ? $hint->{list} : [ $hint->{list} ],
    };
    return $self;
}

sub _quote {
    my ($self, $label) = @_;

    return $$label if ref $label;
    SQL::Builder::Util::quote_identifier($label, $self->{quote_char}, $self->{name_sep})
}

sub as_sql {
    my $self = shift;
    my $sql = '';
    if (@{ $self->{select} }) {
        $sql .= $self->{prefix};
        $sql .= 'DISTINCT ' if $self->{distinct};
        $sql .= join(', ',  map {
            my $alias = $self->{select_map}->{$_};
            if (!$alias) {
                $self->_quote($_)
            } elsif ($alias && $_ =~ /(?:^|\.)\Q$alias\E$/) {
                $self->_quote($_)
            } else {
                $self->_quote($_) . ' AS ' .  $self->_quote($alias)
            }
        } @{ $self->{select} }) . "\n";
    }

    $sql .= 'FROM ';

    ## Add any explicit JOIN statements before the non-joined tables.
    if ($self->{joins} && @{ $self->{joins} }) {
        my $initial_table_written = 0;
        for my $j (@{ $self->{joins} }) {
            my ($table, $join) = map { $j->{$_} } qw( table joins );
            $table = $self->_add_index_hint($table); ## index hint handling
            $sql .= $table unless $initial_table_written++;
            $sql .= ' ' . uc($join->{type}) . ' JOIN ' . $self->_quote($join->{table});
            $sql .= ' ' . $self->_quote($join->{alias}) if $join->{alias};

            if (ref $join->{condition} && ref $join->{condition} eq 'ARRAY') {
                $sql .= ' USING ('. join(', ', map { $self->_quote($_) } @{ $join->{condition} }) . ')';
            }
            else {
                $sql .= ' ON ' . $join->{condition};
            }
        }
        $sql .= ', ' if @{ $self->{from} };
    }

    if ($self->{from} && @{ $self->{from} }) {
        $sql .= join ', ',
          map { $self->_add_index_hint($_->[0], $_->[1]) }
             @{ $self->{from} };
    }

    $sql .= "\n";
    $sql .= $self->as_sql_where()   if $self->{where};

    $sql .= $self->as_sql_group_by  if $self->{group_by};
    $sql .= $self->as_sql_having    if $self->{having};
    $sql .= $self->as_sql_order_by  if $self->{order_by};

    $sql .= $self->as_sql_limit     if $self->{limit};

    $sql .= $self->as_sql_for_update;

    return $sql;
}

sub as_sql_limit {
    my $self = shift;
    my $n = $self->{limit} or
        return '';
    die "Non-numerics in limit clause ($n)" if $n =~ /\D/;
    return sprintf "LIMIT %d%s\n", $n,
           ($self->{offset} ? " OFFSET " . int($self->{offset}) : "");
}

sub add_order_by {
    my ($self, $col, $type) = @_;
    push @{$self->{order_by}}, [$col, $type];
    return $self;
}

sub as_sql_order_by {
    my ($self) = @_;

    my @attrs = @{$self->{order_by}};
    return '' unless @attrs;

    return 'ORDER BY '
           . join(', ', map {
                my ($col, $type) = @$_;
                if (ref $col) {
                    $$col
                } else {
                    $type ? $self->_quote($col) . " $type" : $self->_quote($col)
                }
           } @attrs)
           . "\n";
}

sub add_group_by {
    my ($self, $group, $order) = @_;
    push @{$self->{group_by}}, $order ? $self->_quote($group) . " $order" : $self->_quote($group);
    return $self;
}

sub as_sql_group_by {
    my ($self,) = @_;

    my $elems = $self->{group_by};

    return '' if @$elems == 0;

    return 'GROUP BY '
           . join(', ', @$elems)
           . "\n";
}

sub set_where {
    my ($self, $where) = @_;
    $self->{where} = $where;
    return $self;
}

sub add_where {
    my ($self, $col, $val) = @_;

    $self->{where} ||= $self->new_condition();
    $self->{where}->add($col, $val);
    return $self;
}

sub as_sql_where {
    my $self = shift;

    my $where = $self->{where}->as_sql();
    $where ? "WHERE $where\n" : '';
}

sub as_sql_having {
    my $self = shift;
    if ($self->{having}) {
        'HAVING ' . $self->{having}->as_sql . "\n";
    } else {
        ''
    }
}

sub add_having {
    my ($self, $col, $val) = @_;

    if (my $orig = $self->{select_map_reverse}->{$col}) {
        $col = $orig;
    }

    $self->{having} ||= $self->new_condition();
    $self->{having}->add($col, $val);
    return $self;
}

sub as_sql_for_update {
    my $self = shift;
    $self->{for_update} ? ' FOR UPDATE' : '';
}

sub _add_index_hint {
    my ($self, $tbl_name, $alias) = @_;
    my $quoted = $alias ? $self->_quote($tbl_name) . ' ' . $self->_quote($alias) : $self->_quote($tbl_name);
    my $hint = $self->{index_hint}->{$tbl_name};
    return $quoted unless $hint && ref($hint) eq 'HASH';
    if ($hint->{list} && @{ $hint->{list} }) {
        return $quoted . ' ' . uc($hint->{type} || 'USE') . ' INDEX (' . 
                join (',', map { $self->_quote($_) } @{ $hint->{list} }) .
                ')';
    }
    return $quoted;
}

1;
__END__

=head1 NAME

SQL::Builder::Select - dynamic SQL generator

=head1 SYNOPSIS

    my $sql = SQL::Builder::Select->new()
                                  ->add_select('foo')
                                  ->add_select('bar')
                                  ->add_select('baz')
                                  ->add_from('table_name')
                                  ->as_sql;
    # => "SELECT foo, bar, baz FROM table_name"

=head1 DESCRIPTION

=head1 METHODS

=over 4

=item my $sql = $stmt->as_sql();

Render the sql string.

=item my @bind = $stmt->bind();

Get bind variables.

=item $stmt->add_select('*')

=item $stmt->add_select($col => $alias)

=item $stmt->add_select(\'COUNT(*)' => 'cnt')

Add new select term. It's quote automatically.

=item $stmt->add_from('user');

Add new from term.

=item $stmt->add_join(user => {type => 'inner', table => 'config', condition => 'user.user_id = config.user_id'});

=item $stmt->add_join(user => {type => 'inner', table => 'config', condition => ['user_id']});

Add new JOIN clause. If you pass arrayref for 'condition' then it uses 'USING'.

    my $stmt = SQL::Builder::Select->new();
    $stmt->add_join(
        user => {
            type      => 'inner',
            table     => 'config',
            condition => 'user.user_id = config.user_id',
        }
    );
    $stmt->as_sql();
    # => 'FROM user INNER JOIN config ON user.user_id = config.user_id'


    my $stmt = SQL::Builder::Select->new();
    $stmt->add_select('name');
    $stmt->add_join(
        user => {
            type      => 'inner',
            table     => 'config',
            condition => ['user_id'],
        }
    );
    $stmt->as_sql();
    # => 'SELECT name FROM user INNER JOIN config USING (user_id)'

=item $stmt->add_index_hint(foo => {type => 'USE', list => ['index_hint']});

    my $stmt = SQL::Builder::Select->new();
    $stmt->add_select('name');
    $stmt->add_from('user');
    $stmt->add_index_hint(user => {type => 'USE', list => ['index_hint']});
    $stmt->as_sql();
    # => "SELECT name FROM user USE INDEX (index_hint)"

=item $stmt->add_where('foo_id' => 'bar');

Add new where clause.

    my $stmt = SQL::Builder::Select->new()
                                   ->add_select('c')
                                   ->add_from('foo')
                                   ->add_where('name' => 'john')
                                   ->add_where('type' => {IN => [qw/1 2 3/]})
                                   ->as_sql();
    # => "SELECT c FROM foo WHERE (name = ?) AND (type IN (?,?,?))"

=item $stmt->set_where($condition)

Set the where clause.

$condition should be instance of L<SQL::Builder::Condition>.

    my $cond1 = SQL::Builder::Condition->new()
                                       ->add("name" => "john");
    my $cond2 = SQL::Builder::Condition->new()
                                       ->add("type" => {IN => [qw/1 2 3/]});
    my $stmt = SQL::Builder::Select->new()
                                   ->add_select('c')
                                   ->add_from('foo')
                                   ->set_where($cond1 & $cond2)
                                   ->as_sql();
    # => "SELECT c FROM foo WHERE ((name = ?)) AND ((type IN (?,?,?)))"

=item $stmt->add_order_by('foo');

=item $stmt->add_order_by({'foo' => 'DESC'});

Add new order by clause.

    my $stmt = SQL::Builder::Select->new()
                                   ->add_select('c')
                                   ->add_from('foo')
                                   ->add_order_by('name' => 'DESC')
                                   ->add_order_by('id')
                                   ->as_sql();
    # => "SELECT c FROM foo ORDER BY name DESC, id"

=item $stmt->add_group_by('foo');

Add new GROUP BY clause.

    my $stmt = SQL::Builder::Select->new()
                                   ->add_select('c')
                                   ->add_from('foo')
                                   ->add_group_by('id')
                                   ->as_sql();
    # => "SELECT c FROM foo GROUP BY id"

    my $stmt = SQL::Builder::Select->new()
                                   ->add_select('c')
                                   ->add_from('foo')
                                   ->add_group_by('id' => 'DESC')
                                   ->as_sql();
    # => "SELECT c FROM foo GROUP BY id DESC"

=item $stmt->add_having(cnt => 2)

Add having clause

    my $stmt = SQL::Builder::Select->new()
                                   ->add_from('foo')
                                   ->add_select(\'COUNT(*)' => 'cnt')
                                   ->add_having(cnt => 2)
                                   ->as_sql();
    # => "SELECT COUNT(*) AS cnt FROM foo HAVING (COUNT(*) = ?)"

=back

=head1 SEE ALSO

+<Data::ObjectDriver::SQL>

