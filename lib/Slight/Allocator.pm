use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Digest::MD5 ();

use Slight::Term;
use Slight::Allocator::Utils;

## -----------------------------------------------------------------------------
## ALLOCATOR NOTES:
## -----------------------------------------------------------------------------
## - Cons can create improper lists
##      - ... and other places I need to add type checks
## -----------------------------------------------------------------------------

class Index {
    field $idx  :param :reader;
    field $hash :param :reader;
    field $type :param :reader;
}

class Allocator {
    field @memory :reader;
    field %intern :reader;
    field %native :reader;
    field $stats  :reader = +{
        total_requests   => 0,
        total_created    => 0,
        requests_by_hash => +{},
        created_by_type  => +{},
    };

    field $Nil;
    field $True;
    field $False;

    field $Util :reader;

    method deref_hash   ($hash)  { $memory[ $intern{ $hash }->idx ] }
    method deref_index  ($index) { $memory[ $index->idx  ] }
    method deref_native ($index) { $native{ $index->hash } }

    my method intern ($type, @payload) {
        # NOTE: I know, I know, MD5 is just a placeholder
        my $hash = Digest::MD5::md5_hex(
            join '/' => $type,
                join ':' =>
                    map { blessed $_ ? $_->index->hash : $_ } @payload
        );
        $stats->{total_requests}++;
        $stats->{requests_by_hash}->{ $hash }++;
        return $memory[ $intern{ $hash }->idx ] if exists $intern{ $hash };
        $stats->{created_by_type}->{ $type }++;
        $stats->{total_created}++;
        my $index = Index->new( type => $type, idx => (scalar @memory), hash => $hash );
        my $value = $type->new(
            index => $index,
            data  => [ map { blessed $_ ? $_->index : $_ } @payload ]
        );
        push @memory => $value;
        $intern{$hash} = $index;
        return $value;
    }

    ADJUST {
        $Nil   = $self->&intern( Nil  => '()' );
        $True  = $self->&intern( Bool => '#t' );
        $False = $self->&intern( Bool => '#f' );
        $Util  = Allocator::Utils->new( alloc => $self );
    }

    method Nil   { $Nil }
    method True  { $True }
    method False { $False }

    method Bool ($value) { $value ? $True : $False }
    method Sym  ($ident) { $self->&intern( Sym  => $ident ) }
    method Num  ($value) { $self->&intern( Num  => $value ) }
    method Str  ($value) { $self->&intern( Str  => $value ) }
    method Cons ($h, $t) { $self->&intern( Cons => $h, $t ) }
    method Pair ($f, $s) { $self->&intern( Pair => $f, $s ) }
    method Env  ($p, $r) { $self->&intern( Env  => $p, $r ) }

    method Binding ($s, $t) {
        $self->&intern( Binding => $s, $t )
    }

    method Condition ($c, $t, $f) {
        $self->&intern( Condition => $c, $t, $f )
    }

    method Lambda ($p, $b, $e, $name=undef) {
        $self->&intern( Lambda => $p, $b, $e, $name // () )
    }

    method Partial ($p, $b, $name=undef) {
        $self->&intern( Partial => $p, $b, $name // () )
    }

    method Builtin ($name, $f) {
        my $bif = $self->&intern( Builtin => $name );
        $native{ $bif->index->hash } //= $f;
        return $bif;
    }
}
