
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Digest::MD5 ();

class Term {
    use overload '""' => 'to_string';
    field $hash :param :reader;
    sub hash_of (@args) { Digest::MD5::md5_hex( @args ) }
    method to_string { __CLASS__ }
}

class Literal :isa(Term) {
    field $raw :reader :param;
    method to_string { sprintf '%s(%s)' => __CLASS__, $raw }
}

class Null :isa(Literal) {}
class Bool :isa(Literal) {}
class Num  :isa(Literal) {}
class Str  :isa(Literal) {}
class Sym  :isa(Literal) {}

class Triple :isa(Term) {
    field $subject   :reader :param;
    field $predicate :reader :param;
    field $object    :reader :param;

    method to_string {
        sprintf '(%s %s %s)' => $subject->raw, $predicate->raw, $object->raw }
}

class KnowledgeBase {
    field %terms;

    field %findex;
    field %rindex;

    field $Null;
    field $True;
    field $False;

    ADJUST {
        $Null  = Null->new(hash => Null->hash_of('null'),  raw => 'null');
        $True  = Bool->new(hash => Bool->hash_of('true'),  raw => 'true');
        $False = Bool->new(hash => Bool->hash_of('false'), raw => 'false');
    }

    method Null  { $Null  }
    method True  { $True  }
    method False { $False }

    method Num ($n) {
        my $hash = Num->hash_of($n);
        $terms{ $hash } //= Num->new( hash => $hash, raw => $n );
    }

    method Str ($s) {
        my $hash = Str->hash_of($s);
        $terms{ $hash } //= Str->new( hash => $hash, raw => $s );
    }

    method Sym ($s) {
        my $hash = Sym->hash_of($s);
        $terms{ $hash } //= Sym->new( hash => $hash, raw => $s );
    }

    my method index_fact ($s, $p, $o, $fact) {
        (($findex{ $s->hash } //= +{})
              ->{ $p->hash } //= +{})
              ->{ $o->hash }
                = (($rindex{ $o->hash } //= +{})
                    ->{ $p->hash } //= +{})
                    ->{ $s->hash }
                        = $fact;
    }

    method Triple ($s, $p, $o) {
        my $hash = Triple->hash_of( $s->hash, $p->hash, $o->hash );
        $terms{ $hash } //= $self->&index_fact( $s, $p, $o, Triple->new(
            hash      => $hash,
            subject   => $s,
            predicate => $p,
            object    => $o
        ));
    }

    method contains ($hash) { exists $terms{$hash} }
    method lookup   ($hash) { return $terms{$hash} }

    method query ($s, $p, $o) {
        if (defined $s && defined $p && defined $o) {
            # s p o
            return $findex{ $s->hash }->{ $p->hash }->{ $o->hash };
        }
        elsif (defined $s && defined $p && not(defined $o)) {
            # s p _
            return values $findex{ $s->hash }->{ $p->hash }->%*;
        }
        elsif (defined $s && not(defined $p) && defined $o) {
            # s _ o
            return map  { $findex{ $s->hash }->{ $_ }->{ $o->hash } }
                   grep { exists $rindex{ $o->hash } && exists $rindex{ $o->hash }->{ $_ } }
                   keys $findex{ $s->hash }->%*;
        }
        elsif (not(defined $s) && defined $p && defined $o) {
            # _ p o
            return values $rindex{ $o->hash }->{ $p->hash }->%*;
        }
        elsif (defined $s && not(defined $p) && not(defined $o)) {
            # s _ _
            return map {
                    my $_p = $_;
                    map {
                        $findex{ $s->hash }->{$_p}->{$_}
                    } keys $findex{ $s->hash }->{$_p}->%*
                } keys $findex{ $s->hash }->%*;
        }
        elsif (not(defined $s) && not(defined $p) && defined $o) {
            # _ _ o
            return map {
                    my $_p = $_;
                    map {
                        $rindex{ $o->hash }->{$_p}->{$_}
                    } keys $rindex{ $o->hash }->{$_p}->%*
                } keys $rindex{ $o->hash }->%*;
        }
        elsif (not(defined $s) && defined $p && not(defined $o)) {
            # _ p _
            return map {
                exists $findex{ $_ }->{ $p->hash }
                    ? values $findex{ $_ }->{ $p->hash }->%*
                    : ()
            } keys %findex;
        }
        else {
            die "You must specify at least two parameters";
        }
    }
}

my $kb = KnowledgeBase->new;


my $bob   = $kb->Sym('Bob');
my $alice = $kb->Sym('Alice');
my $chris = $kb->Sym('Chris');

my $has_first_name = $kb->Sym('has-first-name');
my $has_last_name  = $kb->Sym('has-last-name');
my $has_age        = $kb->Sym('has-age');
my $knows          = $kb->Sym('knows?');
my $works_with     = $kb->Sym('works-with?');

my @facts = (
    $kb->Triple( $bob, $has_first_name, $kb->Str("Robert") ),
    $kb->Triple( $bob, $has_last_name,  $kb->Str("Smith") ),
    $kb->Triple( $bob, $has_age,        $kb->Num(50) ),

    $kb->Triple( $alice, $has_first_name, $kb->Str("Allison") ),
    $kb->Triple( $alice, $has_last_name,  $kb->Str("Chains") ),
    $kb->Triple( $alice, $has_age,        $kb->Num(40) ),

    $kb->Triple( $chris, $has_first_name, $kb->Str("Christopher") ),
    $kb->Triple( $chris, $has_last_name,  $kb->Str("Cross") ),
    $kb->Triple( $chris, $has_age,        $kb->Num(60) ),

    $kb->Triple( $bob, $knows, $alice ),
    $kb->Triple( $bob, $knows, $chris ),
    $kb->Triple( $chris, $knows, $bob ),
    $kb->Triple( $alice, $knows, $bob ),
    $kb->Triple( $alice, $knows, $chris ),
    $kb->Triple( $alice, $works_with, $chris ),
    $kb->Triple( $chris, $works_with, $alice ),
);

say $_ foreach @facts;
say '-' x 100;
say '( alice _          chris) = ', join ', ' => $kb->query( $alice,   undef,     $chris );
say '( _     works-with alice) = ', join ', ' => $kb->query( undef,   $works_with, $alice );
say '( bob _       _     ) = ', join ', ' => $kb->query( $bob, undef, undef );
say '( _   _       chris ) = ', join ', ' => $kb->query( undef, undef, $chris );
say '( _   has-age _     ) = ', join ', ' => $kb->query( undef, $has_age, undef );



