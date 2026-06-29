use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];
use Data::Dumper qw[ Dumper ];

use constant DEBUG => $ENV{DEBUG} // 0;
use Term::ReadKey (); our $TERM_WIDTH = (Term::ReadKey::GetTerminalSize)[0];

use Digest::MD5 ();

## -----------------------------------------------------------------------------

class Term {
    field $index :param :reader;
    field $data  :param :reader;
    method is_nil { false }
    method equal_to ($o) { $index->hash eq $o->index->hash }
}

class Sym     :isa(Term) { method ident { $self->data->[0] } }
class Str     :isa(Term) { method value { $self->data->[0] } }
class Num     :isa(Term) { method value { $self->data->[0] } }
class Bool    :isa(Term) { method value { $self->data->[0] } }
class Nil     :isa(Term) { method is_nil { true } }
class Cons    :isa(Term) {
    method head { $self->data->[0] }
    method tail { $self->data->[1] }
}

# Env is a list of pairs
class Env :isa(Cons) {}

# Pair is a cons where tail is not a list
class Pair :isa(Cons) {
    method first  { $self->head }
    method second { $self->tail }
}

class Lambda :isa(Term) {
    method params { $self->data->[0] }
    method body   { $self->data->[1] }
    method env    { $self->data->[2] }
}

class Condition :isa(Term) {
    method cond     { $self->data->[0] }
    method if_true  { $self->data->[1] }
    method if_false { $self->data->[2] }
}

class Builtin :isa(Term) {
    method name { $self->data->[0] }
    method raw  { $self->data->[1] }
}

## -----------------------------------------------------------------------------

class Allocator::Utils {
    field $alloc :param :reader;

    ## ... environs

    method InitEnv (@bindings) {
        my $env = $alloc->Nil;
        foreach my ($sym, $val) (@bindings) {
            $env = $alloc->Env( $alloc->Pair( $sym, $val ), $env );
        }
        return $env;
    }

    method Lookup ($sym, $env) {
        return undef if $env->is_nil;
        my $candidate = $self->First($env);
        if ($self->First($candidate)->equal_to($sym)) {
            return $self->Second($candidate);
        } else {
            return $self->Lookup($sym, $self->Rest($env));
        }
    }

    method BindSymbol ($sym, $val, $env) {
        $alloc->Env( $alloc->Pair( $sym, $val ), $env )
    }

    method BindParams ($params, $args, $env) {
        my @params = $alloc->Util->Uncons($params);
        my @args   = $alloc->Util->Uncons($args);
        die sprintf 'Arity mismatch, got(%s) expected(%s)' => (scalar @args), (scalar @params)
            unless scalar @args == scalar @params;
        my $local = $env;
        while (@params) {
            $local = $self->BindSymbol( shift @params, shift @args, $local )
        }
        return $local;
    }

    ## ... accessors

    method First  ($t) { $alloc->deindex($t->data->[0]) }
    method Second ($t) { $alloc->deindex($t->data->[1]) }
    method Third  ($t) { $alloc->deindex($t->data->[2]) }

    method Rest   ($t) { $alloc->deindex($t->data->[1]) }
    method Head   ($l) { $alloc->deindex($l->data->[0]) }
    method Tail   ($l) { $alloc->deindex($l->data->[1]) }

    ## ... lists

    method ListOf (@list) {
        my $list = $alloc->Nil;
        while (@list) {
            $list = $alloc->Cons( pop @list, $list );
        }
        return $list;
    }

    method Uncons ($list) {
        my @list;
        until ($list->is_nil) {
            push @list => $self->Head( $list );
            $list = $self->Tail( $list );
        }
        return @list;
    }

    ## ... printing and debugging

    method pprint ($t) {
        given (blessed $t) {
            when ('Sym')     { $t->ident }
            when ('Str')     { $t->value }
            when ('Num')     { $t->value }
            when ('Bool')    { $t->value }
            when ('Nil')     { '#nil' }
            when ('Cons')    { sprintf '(%s)' => join ' ' => map $self->pprint($_), $alloc->Util->Uncons($t) }
            when ('Pair')    { sprintf '(%s . %s)' => $self->pprint($self->First($t)), $self->pprint($self->Second($t)) }
            when ('Env')     { sprintf '{ %s }' => join ' ' => map $self->pprint($_), $alloc->Util->Uncons($t) }
            when ('Builtin') { sprintf '<%s>' => $self->pprint($self->First($t)) }
            when ('Lambda')  {
                sprintf '(<lambda> %s %s)' =>
                    $self->pprint($self->First($t)),
                    $self->pprint($self->Second($t))
            }
            when ('Condition') {
                sprintf '(<if> %s %s %s)' =>
                    $self->pprint($self->First($t)),
                    $self->pprint($self->Second($t)),
                    $self->pprint($self->Third($t))
            }
            default { die "WTF! $self" }
        }
    }

    method DUMP ($t) {
        sprintf(
            '$(%05d) | %-9s | %s | %-26s | %s',
            $t->index->idx,
            (blessed $t),
            (substr $t->index->hash, 0, 6),
            (join ' ' => map {
                blessed $_
                    ? (sprintf '$(%05d)' => $_->idx)
                    : (length $_ > 22 ? (substr($_, 0, 22).' ...') : $_)
            } $t->data->@*),
            $self->pprint($t)
        )
    }
}

class Index {
    field $idx  :param :reader;
    field $hash :param :reader;
}

class Allocator {
    field @memory :reader;
    field %intern :reader;
    field %native :reader;

    field $Nil;
    field $True;
    field $False;

    field $Util :reader;

    method deindex ($index) { $memory[ $index->idx ] }
    method deref   ($index) { $native{ $index->hash } }

    my method intern ($type, @payload) {
        my $hash  = Digest::MD5::md5_hex( join '/' => $type, join ':' => @payload );
        return $memory[ $intern{ $hash }->idx ] if exists $intern{ $hash };
        my $index = Index->new( idx => (scalar @memory), hash => $hash );
        my $value = $type->new(
            index => $index,
            data  => [ map blessed $_ ? $_->index : $_, @payload ]
        );
        push @memory => $value;
        $intern{$hash} = $index;
        return $value;
    }

    ADJUST {
        $Nil   = $self->&intern( Nil  => '#nil'   );
        $True  = $self->&intern( Bool => '#true'  );
        $False = $self->&intern( Bool => '#false' );
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

    method Lambda    ($p, $b, $e) { $self->&intern( Lambda    => $p, $b, $e ) }
    method Condition ($c, $t, $f) { $self->&intern( Condition => $c, $t, $f ) }

    method Builtin ($name, $f) {
        my $bif = $self->&intern( Builtin => $name );
        $native{ $bif->index->hash } //= $f;
        return $bif;
    }
}

## -----------------------------------------------------------------------------

class Parser {
    field $alloc  :param :reader;
    field @chars  :reader;
    field @tokens :reader;

    method peek    { $chars[0] }
    method advance { shift @chars }

    method skip_whitespace {
        while (@chars) {
            last if $chars[0] =~ /\S/;
            shift @chars
        }
    }

    method skip_until_newline {
        while (@chars) {
            last if $chars[0] =~ /\n/;
            shift @chars
        }
    }

    method push_stack ($value) { push $tokens[-1]->@* => $value }
    method pop_stack           { pop $tokens[-1]->@* }

    method parse ($source) {
        @tokens = (+[]);
        @chars  = split // => $source;
        while (@chars) {
            $self->find_next_token;
        }
        return pop @tokens;
    }

    method find_next_token {
        my $next = $self->advance;
        given ($next) {
            when (/\s/)    { $self->skip_whitespace }
            when (';')     { $self->skip_until_newline }
            when ('(')     { push @tokens => +[] }
            when (')')     { $self->push_stack( $alloc->Util->ListOf( @{ pop @tokens } ) ) }
            when (/[0-9]/) { $self->push_stack( $alloc->Num( $self->parse_number( $next ) ) ) }
            when ('"')     { $self->push_stack( $alloc->Str( $self->parse_string( $next ) ) ) }
            when ('-')     { $self->peek =~ /[0-9]/
                ? $self->push_stack( $alloc->Num( $self->parse_number( $next ) ) )
                : $self->push_stack( $alloc->Sym( $self->parse_symbol( $next ) ) )
            }
            when ('#') {
                given ($self->peek) {
                    when ('t') { $self->advance; $self->push_stack( $alloc->True ) }
                    when ('f') { $self->advance; $self->push_stack( $alloc->False ) }
                    when ('n') { $self->advance; $self->push_stack( $alloc->Nil ) }
                    default {
                        $self->push_stack( $alloc->Sym( $self->parse_symbol( $next ) ) );
                    }
                }
            }
            default {
                $self->push_stack( $alloc->Sym( $self->parse_symbol( $next ) ) );
            }
        }
    }

    method parse_number ($start) {
        $self->peek =~ /[0-9.]/
            ? $self->parse_number( $start . $self->advance )
            : $start;
    }

    method parse_string ($start) {
        if ($self->peek eq '\\') {
            $start .= $self->advance;
            $start .= $self->advance if $self->peek eq '"';
            $self->parse_string( $start );
        } elsif ($self->peek eq '"') {
            $start . $self->advance;
        } else {
            $self->parse_string( $start . $self->advance );
        }
    }

    method parse_symbol ($start) {
        $self->peek !~ /[\s\(\)]/
            ? $self->parse_symbol( $start . $self->advance )
            : $start;
    }
}

## -----------------------------------------------------------------------------

class Compiler {
    field $alloc :param :reader;

    field @environs;

    method compile ($exprs, $env=undef) {
        push @environs => ($env //= $alloc->Util->InitEnv);
        return +[ map $self->compile_expr($_), @$exprs ]
    }

    method compile_expr ($expr) {
        if ($expr isa Cons) {
            my $h = $alloc->Util->Head( $expr );
            my $t = $alloc->Util->Tail( $expr );
            if ($h isa Sym) {
                given ($h->ident) {
                    when ('if') {
                        my ($c, $t, $f) = map $self->compile_expr($_), $alloc->Util->Uncons($t);
                        return $alloc->Condition( $c, $t, $f );
                    }
                    when ('lambda') {
                        my ($p, $b) = $alloc->Util->Uncons($t);
                        return $alloc->Lambda( $p, $self->compile_expr($b), $environs[-1] );
                    }
                    when ('defun') {
                        my ($name, $p, $b) = $alloc->Util->Uncons($t);
                        my $env    = $environs[-1];
                        my $lambda = $alloc->Lambda( $p, $self->compile_expr($b), $env );
                        push @environs => $alloc->Util->BindSymbol( $name, $lambda, $env );
                        return $alloc->Util->First( $environs[-1] ); # return the new pair binding ...
                    }
                    default {
                        if (my $bif = $alloc->Util->Lookup($h, $environs[-1])) {
                            return $alloc->Cons( $bif, $self->compile_expr($t) );
                        }
                    }
                }
            }
            return $alloc->Cons( $self->compile_expr($h), $self->compile_expr($t) );
        } else {
            return $expr;
        }
    }
}

## -----------------------------------------------------------------------------

class Interpreter {

}

## -----------------------------------------------------------------------------

my $a = Allocator->new;
my $p = Parser->new( alloc => $a );
my $c = Compiler->new( alloc => $a );
my $e = $a->Util->InitEnv(
    $a->Sym('=='), $a->Builtin( $a->Sym('=='), sub ($args) {
        my ($n, $m) = $a->Util->Uncons($args);
        return $a->Bool( $n->value == $m->value )
    }),
    $a->Sym('-'), $a->Builtin( $a->Sym('-'), sub ($args) {
        my ($n, $m) = $a->Util->Uncons($args);
        return $a->Num( $n->value - $m->value )
    }),
    $a->Sym('*'), $a->Builtin( $a->Sym('*'), sub ($args) {
        my ($n, $m) = $a->Util->Uncons($args);
        return $a->Num( $n->value * $m->value )
    }),
);


my $parsed = $p->parse(q[

    (defun fact (n)
        (if (== n 0) 1
            (* n (fact (- n 1)))))

]);

my $compiled = $c->compile( $parsed, $e );

say 'PARSED:';
say $a->Util->DUMP($_) foreach @$parsed;
say 'COMPILED:';
say $a->Util->DUMP($_) foreach @$compiled;
say 'MEMORY:';
say $a->Util->DUMP($_) foreach $a->memory;

## -----------------------------------------------------------------------------
