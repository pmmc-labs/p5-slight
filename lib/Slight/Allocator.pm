
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight::Term;

## -----------------------------------------------------------------------------
## Allocator
## -----------------------------------------------------------------------------

class Slight::Allocator {
    field %terms;

    field $Nil;
    field $True;
    field $False;

    ADJUST {
        $Nil   = Slight::Term::Nil->new( hash => Slight::Term::Nil->hash_of('nil') );
        $True  = Slight::Term::Bool->new( raw => true,  hash => Slight::Term::Bool->hash_of('true') );
        $False = Slight::Term::Bool->new( raw => false, hash => Slight::Term::Bool->hash_of('false') );
    }

    method Nil   { $Nil }
    method True  { $True }
    method False { $False }

    method Num ($n) {
        my $hash = Slight::Term::Num->hash_of($n);
        $terms{ $hash } //= Slight::Term::Num->new( raw => $n, hash => $hash )
    }

    method Sym ($s) {
        my $hash = Slight::Term::Sym->hash_of($s);
        $terms{ $hash } //= Slight::Term::Sym->new( raw => $s, hash => $hash )
    }

    method Str ($s) {
        my $hash = Slight::Term::Str->hash_of($s);
        $terms{ $hash } //= Slight::Term::Str->new( raw => $s, hash => $hash )
    }

    method Pair ($f, $s) {
        my $hash = Slight::Term::Pair->hash_of( $f->hash, $s->hash );
        $terms{ $hash } //= Slight::Term::Pair->new( first => $f, second => $s, hash => $hash )
    }

    method Cons ($h, $t) {
        my $hash = Slight::Term::Cons->hash_of( $h->hash, $t->hash );
        $terms{ $hash } //= Slight::Term::Cons->new( head => $h, tail => $t, hash => $hash )
    }

    method List (@items) {
        my $list = $self->Nil;
        while (@items) {
            $list = $self->Cons( pop @items, $list );
        }
        return $list;
    }

    method Lambda ($p, $b, $e, $name=undef) {
        my $hash = Slight::Term::Lambda->hash_of( $p->hash, $b->hash, $e->hash, (defined $name ? $name->hash : ()) );
        $terms{ $hash } //= Slight::Term::Lambda->new( params => $p, body => $b, env => $e, name => $name, hash => $hash )
    }

    method FExpr ($p, $b, $e, $name=undef) {
        my $hash = Slight::Term::FExpr->hash_of( $p->hash, $b->hash, $e->hash, (defined $name ? $name->hash : ()) );
        $terms{ $hash } //= Slight::Term::FExpr->new( params => $p, body => $b, env => $e, name => $name, hash => $hash )
    }

    method Procedure ($b, %opts) {
        my $hash = Slight::Term::Procedure->hash_of( Sub::Util::subname($b) );
        $terms{ $hash } //= Slight::Term::Procedure->new( body => $b, hash => $hash, %opts )
    }

    method Env (@args) {
        my $parent;
        if (blessed $args[0] && $args[0] isa Slight::Term::Env) {
            $parent = shift @args;
        }
        my %local = @args;
        my $hash = Slight::Term::Env->hash_of(
            (defined $parent ? $parent->hash : '*ROOT-ENV*'),
            map { $_, $local{$_}->hash  } sort { $a cmp $b } keys %local
        );
        $terms{ $hash } //= Slight::Term::Env->new( parent => $parent, local => \%local, hash => $hash )
    }
}


